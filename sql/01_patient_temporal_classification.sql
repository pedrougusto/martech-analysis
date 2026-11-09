BEGIN

  DECLARE data_inicial DATE DEFAULT '2019-01-01';
  DECLARE data_final   DATE DEFAULT '2026-08-01';
  DECLARE data_corrente DATE;

  -- =====================================================
  -- TABELAS TEMPORÁRIAS (roda 1x, fora do loop)
  -- =====================================================
  CREATE TEMP TABLE tmp_primeiro_atd_empresa AS
    SELECT nu_cpf_paciente, MIN(dt_atendimento) AS primeiro_ever_empresa
    FROM `analytics-project.analytics_sandbox.tb_dimensoes_class_pac_atd`
    GROUP BY nu_cpf_paciente;

  CREATE TEMP TABLE tmp_primeiro_atd_marca AS
    SELECT nu_cpf_paciente, marca, MIN(dt_atendimento) AS primeiro_ever_marca
    FROM `analytics-project.analytics_sandbox.tb_dimensoes_class_pac_atd`
    GROUP BY nu_cpf_paciente, marca;

  CREATE TEMP TABLE tmp_primeiro_atd_pagamento AS
    SELECT nu_cpf_paciente, desc_operadora, MIN(dt_atendimento) AS primeiro_ever_pagamento
    FROM `analytics-project.analytics_sandbox.tb_dimensoes_class_pac_atd`
    GROUP BY nu_cpf_paciente, desc_operadora;

  CREATE TEMP TABLE tmp_primeiro_atd_produto AS
    SELECT nu_cpf_paciente, tipo_atd_exame, MIN(dt_atendimento) AS primeiro_ever_produto
    FROM `analytics-project.analytics_sandbox.tb_dimensoes_class_pac_atd`
    GROUP BY nu_cpf_paciente, tipo_atd_exame;

  CREATE TEMP TABLE tmp_primeiro_atd_local AS
    SELECT nu_cpf_paciente, tipo_atd_local, MIN(dt_atendimento) AS primeiro_ever_local
    FROM `analytics-project.analytics_sandbox.tb_dimensoes_class_pac_atd`
    GROUP BY nu_cpf_paciente, tipo_atd_local;

  -- =====================================================
  -- LOOP MENSAL (jan/2019 ao mês corrente)
  -- =====================================================
  SET data_corrente = DATE_TRUNC(data_inicial, MONTH);

  WHILE data_corrente <= DATE_TRUNC(data_final, MONTH) DO

    INSERT INTO `analytics-project.analytics_sandbox.tb_temporal_class_pac_atd2`
    WITH
      -- 1) Calendário mensal de análise
      date_array AS (
        SELECT
          data_corrente AS inicio_mes_atual_analise,
          LAST_DAY(data_corrente) AS fim_mes_atual_analise,
          DATE_TRUNC(DATE_SUB(data_corrente, INTERVAL 23 MONTH), MONTH)
            AS atual_menos_24_meses
      ),

      -- 2) BASE DE ATENDIMENTO (últimos 24 meses até o fim do mês em análise)
      atd_template AS (
        SELECT *
        FROM `analytics-project.analytics_sandbox.tb_dimensoes_class_pac_atd`
        WHERE
          dt_atendimento >= DATE_SUB(data_corrente, INTERVAL 24 MONTH)
          AND dt_atendimento <= LAST_DAY(data_corrente)
      ),

      pacientes_base AS (
        SELECT
          nu_cpf_paciente,
          id_atendimento,
          dt_atendimento,
          marca,
          desc_operadora,
          tipo_atd_exame,
          tipo_atd_local,
          MIN(dt_atendimento) AS primeira_data_atendimento,
          MAX(dt_atendimento) AS ultima_data_atendimento
        FROM atd_template
        GROUP BY ALL
      ),

      -- 3) Cálculo de métricas temporais por CPF e dimensões
      metricas_temporais AS (
        SELECT
          dta.inicio_mes_atual_analise,
          dta.fim_mes_atual_analise,
          dta.atual_menos_24_meses,
          atd.dt_atendimento,
          atd.nu_cpf_paciente,
          atd.id_atendimento,
          atd.marca,
          atd.desc_operadora,
          atd.tipo_atd_exame,
          atd.tipo_atd_local,

          -- PRIMEIRO ATENDIMENTO EVER (por dimensão)
          pd.primeiro_ever_empresa,
          pm.primeiro_ever_marca,
          pp.primeiro_ever_pagamento,
          pprod.primeiro_ever_produto,
          pl.primeiro_ever_local,

          -- =========================
          -- MÉTRICAS GERAIS (EMPRESA)
          -- =========================
          COUNT(
            DISTINCT
              CASE
                WHEN
                  atd.dt_atendimento >= dta.atual_menos_24_meses
                  AND atd.dt_atendimento < dta.inicio_mes_atual_analise
                  THEN atd.id_atendimento
                END)
            OVER (
              PARTITION BY dta.inicio_mes_atual_analise, atd.nu_cpf_paciente
            ) AS total_atd_23_meses_empresa,

          COUNT(
            DISTINCT
              CASE
                WHEN
                  atd.dt_atendimento >= dta.inicio_mes_atual_analise
                  AND atd.dt_atendimento <= dta.fim_mes_atual_analise
                  THEN atd.id_atendimento
                END)
            OVER (
              PARTITION BY dta.inicio_mes_atual_analise, atd.nu_cpf_paciente
            ) AS total_atd_mes_atual_empresa,

          -- =========================
          -- MÉTRICAS POR MARCA
          -- =========================
          COUNT(
            DISTINCT
              CASE
                WHEN
                  atd.dt_atendimento >= dta.atual_menos_24_meses
                  AND atd.dt_atendimento < dta.inicio_mes_atual_analise
                  THEN atd.id_atendimento
                END)
            OVER (
              PARTITION BY
                dta.inicio_mes_atual_analise, atd.nu_cpf_paciente, atd.marca
            ) AS total_atd_23_meses_marca,

          COUNT(
            DISTINCT
              CASE
                WHEN
                  atd.dt_atendimento >= dta.inicio_mes_atual_analise
                  AND atd.dt_atendimento <= dta.fim_mes_atual_analise
                  THEN atd.id_atendimento
                END)
            OVER (
              PARTITION BY
                dta.inicio_mes_atual_analise, atd.nu_cpf_paciente, atd.marca
            ) AS total_atd_mes_atual_marca,

          -- =========================
          -- MÉTRICAS POR PAGAMENTO (OPERADORA)
          -- =========================
          COUNT(
            DISTINCT
              CASE
                WHEN
                  atd.dt_atendimento >= dta.atual_menos_24_meses
                  AND atd.dt_atendimento < dta.inicio_mes_atual_analise
                  THEN atd.id_atendimento
                END)
            OVER (
              PARTITION BY
                dta.inicio_mes_atual_analise,
                atd.nu_cpf_paciente,
                atd.desc_operadora
            ) AS total_atd_23_meses_pagamento,

          COUNT(
            DISTINCT
              CASE
                WHEN
                  atd.dt_atendimento >= dta.inicio_mes_atual_analise
                  AND atd.dt_atendimento <= dta.fim_mes_atual_analise
                  THEN atd.id_atendimento
                END)
            OVER (
              PARTITION BY
                dta.inicio_mes_atual_analise,
                atd.nu_cpf_paciente,
                atd.desc_operadora
            ) AS total_atd_mes_atual_pagamento,

          -- =========================
          -- MÉTRICAS POR PRODUTO
          -- =========================
          COUNT(
            DISTINCT
              CASE
                WHEN
                  atd.dt_atendimento >= dta.atual_menos_24_meses
                  AND atd.dt_atendimento < dta.inicio_mes_atual_analise
                  THEN atd.id_atendimento
                END)
            OVER (
              PARTITION BY
                dta.inicio_mes_atual_analise,
                atd.nu_cpf_paciente,
                atd.tipo_atd_exame
            ) AS total_atd_23_meses_produto,

          COUNT(
            DISTINCT
              CASE
                WHEN
                  atd.dt_atendimento >= dta.inicio_mes_atual_analise
                  AND atd.dt_atendimento <= dta.fim_mes_atual_analise
                  THEN atd.id_atendimento
                END)
            OVER (
              PARTITION BY
                dta.inicio_mes_atual_analise,
                atd.nu_cpf_paciente,
                atd.tipo_atd_exame
            ) AS total_atd_mes_atual_produto,

          -- =========================
          -- MÉTRICAS POR LOCAL
          -- =========================
          COUNT(
            DISTINCT
              CASE
                WHEN
                  atd.dt_atendimento >= dta.atual_menos_24_meses
                  AND atd.dt_atendimento < dta.inicio_mes_atual_analise
                  THEN atd.id_atendimento
                END)
            OVER (
              PARTITION BY
                dta.inicio_mes_atual_analise,
                atd.nu_cpf_paciente,
                atd.tipo_atd_local
            ) AS total_atd_23_meses_local,

          COUNT(
            DISTINCT
              CASE
                WHEN
                  atd.dt_atendimento >= dta.inicio_mes_atual_analise
                  AND atd.dt_atendimento <= dta.fim_mes_atual_analise
                  THEN atd.id_atendimento
                END)
            OVER (
              PARTITION BY
                dta.inicio_mes_atual_analise,
                atd.nu_cpf_paciente,
                atd.tipo_atd_local
            ) AS total_atd_mes_atual_local

        FROM pacientes_base atd
        CROSS JOIN date_array dta
        LEFT JOIN tmp_primeiro_atd_empresa pd
          ON atd.nu_cpf_paciente = pd.nu_cpf_paciente
        LEFT JOIN tmp_primeiro_atd_marca pm
          ON atd.nu_cpf_paciente = pm.nu_cpf_paciente
          AND atd.marca = pm.marca
        LEFT JOIN tmp_primeiro_atd_pagamento pp
          ON atd.nu_cpf_paciente = pp.nu_cpf_paciente
          AND (atd.desc_operadora = pp.desc_operadora
               OR (atd.desc_operadora IS NULL AND pp.desc_operadora IS NULL))
        LEFT JOIN tmp_primeiro_atd_produto pprod
          ON atd.nu_cpf_paciente = pprod.nu_cpf_paciente
          AND atd.tipo_atd_exame = pprod.tipo_atd_exame
        LEFT JOIN tmp_primeiro_atd_local pl
          ON atd.nu_cpf_paciente = pl.nu_cpf_paciente
          AND atd.tipo_atd_local = pl.tipo_atd_local
        WHERE
          dta.inicio_mes_atual_analise >= DATE_TRUNC(
            atd.primeira_data_atendimento, MONTH)
      ),

      -- 4) Aplicar classificações
      classificacoes AS (
        SELECT
          inicio_mes_atual_analise,
          nu_cpf_paciente,
          id_atendimento,
          dt_atendimento,
          marca,
          desc_operadora,
          tipo_atd_exame,
          tipo_atd_local,

          -- CLASSIFICAÇÃO EMPRESA (GERAL)
          CASE
            WHEN primeiro_ever_empresa >= inicio_mes_atual_analise
              AND total_atd_mes_atual_empresa > 0
              THEN 'novo'
            WHEN primeiro_ever_empresa < inicio_mes_atual_analise
              AND total_atd_23_meses_empresa = 0
              AND total_atd_mes_atual_empresa > 0
              THEN 'recuperado'
            WHEN primeiro_ever_empresa < inicio_mes_atual_analise
              AND total_atd_23_meses_empresa = 0
              AND total_atd_mes_atual_empresa = 0
              THEN 'churn'
            WHEN (total_atd_23_meses_empresa + total_atd_mes_atual_empresa) >= 2
              THEN 'recorrente'
            WHEN total_atd_23_meses_empresa = 1
              AND total_atd_mes_atual_empresa = 0
              THEN 'inativo'
            ELSE 'error'
            END AS classificacao_paciente_empresa,

          -- CLASSIFICAÇÃO POR MARCA
          CASE
            WHEN marca IS NULL THEN NULL
            WHEN primeiro_ever_marca >= inicio_mes_atual_analise
              AND total_atd_mes_atual_marca > 0
              THEN 'novo'
            WHEN primeiro_ever_marca < inicio_mes_atual_analise
              AND total_atd_23_meses_marca = 0
              AND total_atd_mes_atual_marca > 0
              THEN 'recuperado'
            WHEN primeiro_ever_marca < inicio_mes_atual_analise
              AND total_atd_23_meses_marca = 0
              AND total_atd_mes_atual_marca = 0
              THEN 'churn'
            WHEN (total_atd_23_meses_marca + total_atd_mes_atual_marca) >= 2
              THEN 'recorrente'
            WHEN total_atd_23_meses_marca = 1
              AND total_atd_mes_atual_marca = 0
              THEN 'inativo'
            ELSE 'error'
            END AS classificacao_paciente_marca,

          -- CLASSIFICAÇÃO POR PAGAMENTO
          CASE
            WHEN desc_operadora IS NULL THEN NULL
            WHEN primeiro_ever_pagamento >= inicio_mes_atual_analise
              AND total_atd_mes_atual_pagamento > 0
              THEN 'novo'
            WHEN primeiro_ever_pagamento < inicio_mes_atual_analise
              AND total_atd_23_meses_pagamento = 0
              AND total_atd_mes_atual_pagamento > 0
              THEN 'recuperado'
            WHEN primeiro_ever_pagamento < inicio_mes_atual_analise
              AND total_atd_23_meses_pagamento = 0
              AND total_atd_mes_atual_pagamento = 0
              THEN 'churn'
            WHEN (total_atd_23_meses_pagamento + total_atd_mes_atual_pagamento) >= 2
              THEN 'recorrente'
            WHEN total_atd_23_meses_pagamento = 1
              AND total_atd_mes_atual_pagamento = 0
              THEN 'inativo'
            ELSE 'error'
            END AS classificacao_paciente_pagamento,

          -- CLASSIFICAÇÃO POR PRODUTO
          CASE
            WHEN tipo_atd_exame IS NULL THEN NULL
            WHEN primeiro_ever_produto >= inicio_mes_atual_analise
              AND total_atd_mes_atual_produto > 0
              THEN 'novo'
            WHEN primeiro_ever_produto < inicio_mes_atual_analise
              AND total_atd_23_meses_produto = 0
              AND total_atd_mes_atual_produto > 0
              THEN 'recuperado'
            WHEN primeiro_ever_produto < inicio_mes_atual_analise
              AND total_atd_23_meses_produto = 0
              AND total_atd_mes_atual_produto = 0
              THEN 'churn'
            WHEN (total_atd_23_meses_produto + total_atd_mes_atual_produto) >= 2
              THEN 'recorrente'
            WHEN total_atd_23_meses_produto = 1
              AND total_atd_mes_atual_produto = 0
              THEN 'inativo'
            ELSE 'error'
            END AS classificacao_paciente_produto,

          -- CLASSIFICAÇÃO POR LOCAL
          CASE
            WHEN tipo_atd_local IS NULL THEN NULL
            WHEN primeiro_ever_local >= inicio_mes_atual_analise
              AND total_atd_mes_atual_local > 0
              THEN 'novo'
            WHEN primeiro_ever_local < inicio_mes_atual_analise
              AND total_atd_23_meses_local = 0
              AND total_atd_mes_atual_local > 0
              THEN 'recuperado'
            WHEN primeiro_ever_local < inicio_mes_atual_analise
              AND total_atd_23_meses_local = 0
              AND total_atd_mes_atual_local = 0
              THEN 'churn'
            WHEN (total_atd_23_meses_local + total_atd_mes_atual_local) >= 2
              THEN 'recorrente'
            WHEN total_atd_23_meses_local = 1
              AND total_atd_mes_atual_local = 0
              THEN 'inativo'
            ELSE 'error'
            END AS classificacao_paciente_local
        FROM metricas_temporais
      )

    SELECT
      atd.mes_atendimento,
      COUNT(DISTINCT atd.id_atendimento) AS atendimentos,
      cp.nu_cpf_paciente,
      atd.sexo_paciente,
      atd.dt_nascimento_paciente,
      atd.marca,
      atd.regional,
      atd.unidades,
      atd.grupo_exames,
      atd.desc_operadora,
      atd.nm_operadora,
      atd.tipo_atd_exame,
      atd.tipo_atd_local,
      atd.faixa_etaria,
      ROUND(SUM(atd.receita), 2) AS receita,
      SUM(atd.vol_exames) AS vol_exames,
      atd.channel_group,
      atd.campaign_non_direct,
      atd.origem_agd,
      atd.jornada_crm,
      atd.canal_crm,
      atd.grupo_interacao_crm,
      cp.inicio_mes_atual_analise,
      cp.classificacao_paciente_empresa,
      cp.classificacao_paciente_marca,
      cp.classificacao_paciente_pagamento,
      cp.classificacao_paciente_produto,
      cp.classificacao_paciente_local
    FROM classificacoes cp
    LEFT JOIN atd_template atd
      ON cp.nu_cpf_paciente = atd.nu_cpf_paciente
        AND cp.id_atendimento = atd.id_atendimento
    GROUP BY ALL;

    SET data_corrente = DATE_ADD(data_corrente, INTERVAL 1 MONTH);

  END WHILE;

  -- Limpa as tabelas temporárias
  DROP TABLE IF EXISTS tmp_primeiro_atd_empresa;
  DROP TABLE IF EXISTS tmp_primeiro_atd_marca;
  DROP TABLE IF EXISTS tmp_primeiro_atd_pagamento;
  DROP TABLE IF EXISTS tmp_primeiro_atd_produto;
  DROP TABLE IF EXISTS tmp_primeiro_atd_local;

END;