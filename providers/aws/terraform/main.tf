# ============================================================================
# AWS deployment profile — minimal, reference (aion-infra amendment §16–18).
# ============================================================================
# The AION → AWS mapping as MINIMAL Terraform, sufficient to prove the workload
# moves without code changes and to define the migration path. It is NOT a full
# productionized platform (§18): no EKS, MSK, ElastiCache, OpenSearch,
# multi-region, or autoscaling beyond managed defaults.
#
#   Internet → ALB (HTTPS) → ECS Fargate (aion-runtime, SAME image)
#                                   │  private
#                                   ▼
#                            RDS PostgreSQL 16 (not public)
#   Secrets → Secrets Manager → task env    Logs → CloudWatch
#   CI identity → GitHub OIDC → IAM role     Backups → RDS automated + PITR
#
# To keep it cheap, Fargate tasks run in public subnets with egress via the IGW
# (no NAT gateway); RDS stays private and non-public. Moving tasks to private
# subnets + NAT (or VPC endpoints) is a documented hardening step.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs     = slice(data.aws_availability_zones.available.names, 0, 2)
  tags    = { Environment = var.environment, ManagedBy = "terraform", Component = "aion" }
  db_url  = "postgresql://aion_app:${var.app_password}@${aws_db_instance.postgres.address}:5432/aion_data?sslmode=require"
  mig_url = "postgresql://aion_migrator:${var.migrator_password}@${aws_db_instance.postgres.address}:5432/aion_data?sslmode=require"
}

# ── Network ─────────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "${var.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = local.tags
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = merge(local.tags, { Name = "${var.name_prefix}-public-${count.index}" })
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.azs[count.index]
  tags              = merge(local.tags, { Name = "${var.name_prefix}-private-${count.index}" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = local.tags
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── Security groups ─────────────────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name_prefix = "${var.name_prefix}-alb-"
  vpc_id      = aws_vpc.main.id
  description = "ALB ingress (public HTTPS/HTTP)."
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}

resource "aws_security_group" "task" {
  name_prefix = "${var.name_prefix}-task-"
  vpc_id      = aws_vpc.main.id
  description = "Fargate task: ingress only from the ALB on 8080."
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}

resource "aws_security_group" "db" {
  name_prefix = "${var.name_prefix}-db-"
  vpc_id      = aws_vpc.main.id
  description = "RDS: ingress only from the Fargate task SG on 5432."
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.task.id]
  }
  tags = local.tags
}

# ── Database (RDS PostgreSQL 16) ────────────────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name_prefix = "${var.name_prefix}-"
  subnet_ids  = aws_subnet.private[*].id
  tags        = local.tags
}

resource "aws_db_instance" "postgres" {
  identifier     = "${var.name_prefix}-pg"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  allocated_storage = var.db_allocated_storage
  storage_encrypted = true
  storage_type      = "gp3"

  db_name  = "aion_data"
  username = "aion_migrator" # RDS master == the DDL/migration role
  password = var.migrator_password
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false # never public (contract §2; §13)

  backup_retention_period   = var.backup_retention_days # > 0 enables PITR
  deletion_protection       = var.deletion_protection
  multi_az                  = var.multi_az
  skip_final_snapshot       = !var.deletion_protection
  final_snapshot_identifier = var.deletion_protection ? "${var.name_prefix}-pg-final" : null
  apply_immediately         = true

  tags = local.tags
}

# ── Image registry ──────────────────────────────────────────────────────────
resource "aws_ecr_repository" "runtime" {
  name                 = "${var.name_prefix}-runtime"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = local.tags
}

# ── Secrets (Secrets Manager → task env) ────────────────────────────────────
resource "aws_secretsmanager_secret" "database_url" {
  name_prefix = "${var.name_prefix}-database-url-"
  tags        = local.tags
}
resource "aws_secretsmanager_secret_version" "database_url" {
  secret_id     = aws_secretsmanager_secret.database_url.id
  secret_string = local.db_url
}

resource "aws_secretsmanager_secret" "migration_database_url" {
  name_prefix = "${var.name_prefix}-migration-database-url-"
  tags        = local.tags
}
resource "aws_secretsmanager_secret_version" "migration_database_url" {
  secret_id     = aws_secretsmanager_secret.migration_database_url.id
  secret_string = local.mig_url
}

# ── Logs ────────────────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "runtime" {
  name              = "/aion/${var.environment}/runtime"
  retention_in_days = var.environment == "production" ? 60 : 30
  tags              = local.tags
}

# ── IAM: task execution (pull image, read secrets, write logs) ──────────────
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name_prefix        = "${var.name_prefix}-exec-"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The RUNTIME execution role may read ONLY the app DATABASE_URL secret; the
# MIGRATE execution role may read ONLY the migration secret (least privilege).
data "aws_iam_policy_document" "read_app_secret" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.database_url.arn]
  }
}
resource "aws_iam_role_policy" "runtime_reads_app_secret" {
  name   = "read-app-secret"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.read_app_secret.json
}

resource "aws_iam_role" "migrate_execution" {
  name_prefix        = "${var.name_prefix}-migexec-"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}
resource "aws_iam_role_policy_attachment" "migrate_execution_managed" {
  role       = aws_iam_role.migrate_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
data "aws_iam_policy_document" "read_migration_secret" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.migration_database_url.arn]
  }
}
resource "aws_iam_role_policy" "migrate_reads_migration_secret" {
  name   = "read-migration-secret"
  role   = aws_iam_role.migrate_execution.id
  policy = data.aws_iam_policy_document.read_migration_secret.json
}

resource "aws_iam_role" "task" {
  name_prefix        = "${var.name_prefix}-task-"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = local.tags
}

# ── ECS cluster + task definitions ──────────────────────────────────────────
resource "aws_ecs_cluster" "main" {
  name = "${var.name_prefix}-cluster"
  tags = local.tags
}

locals {
  runtime_env = [
    { name = "AION_ENVIRONMENT", value = var.environment },
    { name = "NODE_ENV", value = "production" },
    { name = "PORT", value = "8080" },
    { name = "SERVICE_VERSION", value = var.service_version },
    { name = "GIT_SHA", value = var.git_sha },
    { name = "DATABASE_SSL", value = "true" },
  ]
}

# The long-running runtime: receives ONLY DATABASE_URL (never the migration URL).
resource "aws_ecs_task_definition" "runtime" {
  family                   = "${var.name_prefix}-runtime"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name         = "aion-runtime"
    image        = var.image
    essential    = true
    portMappings = [{ containerPort = 8080 }]
    environment  = local.runtime_env
    secrets      = [{ name = "DATABASE_URL", valueFrom = aws_secretsmanager_secret.database_url.arn }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.runtime.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "runtime"
      }
    }
  }])
  tags = local.tags
}

# The migration task: run one-off via `aws ecs run-task`; receives ONLY the
# migration URL and overrides the command to the migrate entrypoint.
resource "aws_ecs_task_definition" "migrate" {
  family                   = "${var.name_prefix}-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.migrate_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name        = "aion-migrate"
    image       = var.image
    essential   = true
    command     = ["node", "dist/migrate.js"]
    environment = local.runtime_env
    secrets     = [{ name = "MIGRATION_DATABASE_URL", valueFrom = aws_secretsmanager_secret.migration_database_url.arn }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.runtime.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "migrate"
      }
    }
  }])
  tags = local.tags
}

# ── Load balancer + service ─────────────────────────────────────────────────
resource "aws_lb" "main" {
  name_prefix        = "aion-"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  tags               = local.tags
}

resource "aws_lb_target_group" "runtime" {
  name_prefix = "aion-"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  # Provider-neutral readiness endpoint drives ALB health (contract §1; §24).
  health_check {
    path                = "/health/ready"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200"
  }
  tags = local.tags
}

# HTTPS when a cert is supplied; otherwise HTTP (dev/plan only — document ACM).
resource "aws_lb_listener" "https" {
  count             = var.certificate_arn == "" ? 0 : 1
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.runtime.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.runtime.arn
  }
}

resource "aws_ecs_service" "runtime" {
  name            = "${var.name_prefix}-runtime"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.runtime.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true # egress to ECR/Secrets via IGW (no NAT)
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.runtime.arn
    container_name   = "aion-runtime"
    container_port   = 8080
  }

  lifecycle {
    ignore_changes = [task_definition] # image/task advanced by the deploy pipeline
  }

  depends_on = [aws_lb_listener.http]
  tags       = local.tags
}

# ── CI identity: GitHub OIDC → deploy role ──────────────────────────────────
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
  tags            = local.tags
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:*"]
    }
  }
}

resource "aws_iam_role" "ci_deploy" {
  name_prefix        = "${var.name_prefix}-ci-"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
  tags               = local.tags
}
