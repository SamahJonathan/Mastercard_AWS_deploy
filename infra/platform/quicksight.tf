# Amazon QuickSight: data source sobre el workgroup de Athena + datasets de Gold en DIRECT_QUERY.
# Requisitos previos (una vez, en la consola de QuickSight): suscribirse (hay prueba gratuita) y en
# "Manage QuickSight > Security & permissions" habilitar Athena y los buckets gold / athena-results con la llave KMS.
# El dashboard se arma sobre estos datasets (ver docs/quicksight.md).

locals {
  qs_count = var.enable_quicksight && var.quicksight_user_arn != "" ? 1 : 0

  qs_datasets = {
    interchange_settlement = {
      name = "Liquidación de intercambio"
      columns = {
        txn_date           = "STRING", issuer_id = "STRING", issuer_name = "STRING", acquirer_id = "STRING",
        txn_count          = "INTEGER", amount_usd = "DECIMAL", interchange_fee_usd = "DECIMAL",
        cross_border_count = "INTEGER", effective_rate = "DECIMAL"
      }
    }
    daily_merchant_kpis = {
      name = "KPIs diarios por comercio"
      columns = {
        txn_date         = "STRING", merchant_id = "STRING", merchant_name = "STRING", mcc = "STRING",
        mcc_category     = "STRING", merchant_country = "STRING", txn_count = "INTEGER", approved_count = "INTEGER",
        gross_amount_usd = "DECIMAL", approval_rate = "DECIMAL", avg_ticket_usd = "DECIMAL"
      }
    }
    fraud_alerts = {
      name = "Alertas de fraude"
      columns = {
        txn_date   = "STRING", transaction_id = "STRING", event_ts = "DATETIME", pan_last4 = "STRING",
        issuer_id  = "STRING", merchant_id = "STRING", merchant_country = "STRING", entry_mode = "STRING",
        amount_usd = "DECIMAL", txn_count_10m = "INTEGER", rules = "STRING", risk_score = "INTEGER"
      }
    }
    cross_border_corridors = {
      name = "Corredores transfronterizos"
      columns = {
        txn_date  = "STRING", card_country = "STRING", merchant_country = "STRING",
        txn_count = "INTEGER", amount_usd = "DECIMAL"
      }
    }
  }
}

resource "aws_quicksight_data_source" "athena" {
  count          = local.qs_count
  data_source_id = "${local.name}-athena"
  name           = "Payments Lakehouse (Athena)"
  type           = "ATHENA"

  parameters {
    athena {
      work_group = aws_athena_workgroup.analytics.name
    }
  }

  permission {
    principal = var.quicksight_user_arn
    actions = [
      "quicksight:DescribeDataSource", "quicksight:DescribeDataSourcePermissions", "quicksight:PassDataSource",
      "quicksight:UpdateDataSource", "quicksight:DeleteDataSource", "quicksight:UpdateDataSourcePermissions",
    ]
  }
}

resource "aws_quicksight_data_set" "gold" {
  for_each    = local.qs_count == 1 ? local.qs_datasets : {}
  data_set_id = "${local.name}-${replace(each.key, "_", "-")}"
  name        = each.value.name
  import_mode = "DIRECT_QUERY"

  physical_table_map {
    physical_table_map_id = each.key
    relational_table {
      data_source_arn = aws_quicksight_data_source.athena[0].arn
      catalog         = "AwsDataCatalog"
      schema          = aws_glue_catalog_database.layer["gold"].name
      name            = each.key

      dynamic "input_columns" {
        for_each = each.value.columns
        content {
          name = input_columns.key
          type = input_columns.value
        }
      }
    }
  }

  permissions {
    principal = var.quicksight_user_arn
    actions = [
      "quicksight:DescribeDataSet", "quicksight:DescribeDataSetPermissions", "quicksight:PassDataSet",
      "quicksight:DescribeIngestion", "quicksight:ListIngestions", "quicksight:UpdateDataSet",
      "quicksight:DeleteDataSet", "quicksight:CreateIngestion", "quicksight:CancelIngestion",
      "quicksight:UpdateDataSetPermissions",
    ]
  }

  depends_on = [aws_lakeformation_permissions.reader_tables]
}
