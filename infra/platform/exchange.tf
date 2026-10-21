# Intercambio de datos B2B: cada emisor asume SU rol y sólo puede leer SU carpeta de liquidaciones.
# En producción partner_principal_arn sería la cuenta AWS del banco; aquí, por defecto, la propia cuenta.

resource "random_password" "partner_external_id" {
  for_each = toset(var.partner_issuers)
  length   = 24
  special  = false
}

data "aws_iam_policy_document" "partner_trust" {
  for_each = toset(var.partner_issuers)
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [coalesce(var.partner_principal_arn, "arn:aws:iam::${local.account_id}:root")]
    }
    # ExternalId mitiga el problema del "confused deputy" en accesos entre cuentas
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [random_password.partner_external_id[each.key].result]
    }
  }
}

data "aws_iam_policy_document" "partner" {
  for_each = toset(var.partner_issuers)
  statement {
    sid       = "ListOwnPrefix"
    actions   = ["s3:ListBucket"]
    resources = [local.arn["exchange"]]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["outbound/issuer_id=${each.key}/*"]
    }
  }
  statement {
    sid       = "ReadOwnFiles"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${local.arn["exchange"]}/outbound/issuer_id=${each.key}/*"]
  }
  statement {
    sid       = "Decrypt"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.lake.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "partner" {
  for_each           = toset(var.partner_issuers)
  name               = "${local.name}-partner-${lower(each.key)}"
  assume_role_policy = data.aws_iam_policy_document.partner_trust[each.key].json
}

resource "aws_iam_role_policy" "partner" {
  for_each = toset(var.partner_issuers)
  name     = "read-own-settlements"
  role     = aws_iam_role.partner[each.key].id
  policy   = data.aws_iam_policy_document.partner[each.key].json
}
