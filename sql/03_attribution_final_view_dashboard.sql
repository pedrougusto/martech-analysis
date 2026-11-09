create or replace view analytics-project.analytics_sandbox.vw_atribuicao_final_dash as (

WITH params AS (
  SELECT DATE '2025-01-01' AS dt_ini, CURRENT_DATE() AS dt_fim
),

base_tp AS (
  SELECT
    a.*,
    atd.desc_operadora,
    atd.sg_uf_paciente,
    atd.cd_sexo_paciente,
    atd.faixa_etaria,
    atd.nm_regional_unidade,
    atd.nm_marca_unidade,
    atd.nm_grupo_mercado_exame,
    atd.tipo_atd_local
  FROM `analytics-project.analytics_sandbox.tb_atribuicao_final` a
  LEFT JOIN `analytics-project.analytics_sandbox.tb_atribuicao_dimensoes` atd USING (id_atendimento)
  WHERE a.dt_atendimento BETWEEN (SELECT dt_ini FROM params) AND (SELECT dt_fim FROM params)
),

-- Influência
base_tp_influencia AS (
  SELECT
    b.*,
    ROW_NUMBER() OVER (
      PARTITION BY id_atendimento
      ORDER BY dt_touch DESC, eficiencia DESC
    ) AS ordem_toque,
    CASE WHEN canal = canal_last_agd THEN 1 ELSE 0 END AS is_last_agd
  FROM base_tp b
),

-- Classificação Mensal
class_mensal AS (
  SELECT
    nu_cpf_paciente,
    inicio_mes_atual_analise,
    ANY_VALUE(classificacao_paciente_empresa) AS classificacao_paciente_empresa,
    ANY_VALUE(classificacao_paciente_marca) AS classificacao_paciente_marca,
    ANY_VALUE(classificacao_paciente_pagamento) AS classificacao_paciente_pagamento,
    ANY_VALUE(classificacao_paciente_produto) AS classificacao_paciente_produto,
    ANY_VALUE(classificacao_paciente_local) AS classificacao_paciente_local
  FROM `analytics-project.analytics_sandbox.tb_temporal_class_pac_atd2`
  WHERE mes_atendimento >= DATE '2025-01-01'
  GROUP BY 1, 2
),

data_driven AS (
  SELECT
    dt_atendimento,
    canal,
    subcanal,
    desc_operadora,
    sg_uf_paciente,
    cd_sexo_paciente,
    faixa_etaria,
    nm_regional_unidade,
    nm_marca_unidade,
    nm_grupo_mercado_exame,
    tipo_atd_local,
    c.classificacao_paciente_empresa,
    c.classificacao_paciente_marca,
    c.classificacao_paciente_pagamento,
    c.classificacao_paciente_produto,
    c.classificacao_paciente_local,
    "Data Driven" AS atribuicao,
    COUNT(*) AS touch_points,
    COUNT(DISTINCT id_atendimento) AS atendimentos,
    SUM(receita_atribuida) AS receita,
    COUNT(DISTINCT cpf) AS pacientes,

    -- Ordem do Toque (Top 5)
    SUM(IF(ordem_toque = 1, 1, 0)) AS tp_ordem_1,
    SUM(IF(ordem_toque = 2, 1, 0)) AS tp_ordem_2,
    SUM(IF(ordem_toque = 3, 1, 0)) AS tp_ordem_3,
    SUM(IF(ordem_toque = 4, 1, 0)) AS tp_ordem_4,
    SUM(IF(ordem_toque = 5, 1, 0)) AS tp_ordem_5,

    SUM(IF(ordem_toque <= 5, 1, 0)) AS touch_points_top5,

    -- Etapa por Touch Position (TP)
    SUM(IF(ordem_toque = 1, 1, 0)) AS tp_final_tp_top5,
    SUM(IF(ordem_toque BETWEEN 2 AND 3, 1, 0)) AS tp_meio_tp_top5,
    SUM(IF(ordem_toque BETWEEN 4 AND 5, 1, 0)) AS tp_inicio_tp_top5,

    COUNT(DISTINCT IF(ordem_toque = 1, id_atendimento, NULL)) AS atd_final_tp_top5,
    COUNT(DISTINCT IF(ordem_toque BETWEEN 2 AND 3, id_atendimento, NULL)) AS atd_meio_tp_top5,
    COUNT(DISTINCT IF(ordem_toque BETWEEN 4 AND 5, id_atendimento, NULL)) AS atd_inicio_tp_top5,

    -- Receita por etapa (Top 5)
    SUM(IF(ordem_toque BETWEEN 4 AND 5, receita_atribuida, 0)) AS receita_inicio_tp_top5,
    SUM(IF(ordem_toque BETWEEN 2 AND 3, receita_atribuida, 0)) AS receita_meio_tp_top5,
    SUM(IF(ordem_toque = 1, receita_atribuida, 0)) AS receita_final_tp_top5,

    -- Receita por ordem (1..5)
    SUM(IF(ordem_toque = 1, receita_atribuida, 0)) AS receita_ordem_1,
    SUM(IF(ordem_toque = 2, receita_atribuida, 0)) AS receita_ordem_2,
    SUM(IF(ordem_toque = 3, receita_atribuida, 0)) AS receita_ordem_3,
    SUM(IF(ordem_toque = 4, receita_atribuida, 0)) AS receita_ordem_4,
    SUM(IF(ordem_toque = 5, receita_atribuida, 0)) AS receita_ordem_5,

    -- Etapa por Dias
    SUM(IF(ordem_toque <= 5 AND dias_antes <= 3, 1, 0)) AS tp_final_dias_top5,
    SUM(IF(ordem_toque <= 5 AND dias_antes BETWEEN 4 AND 10, 1, 0)) AS tp_meio_dias_top5,
    SUM(IF(ordem_toque <= 5 AND dias_antes > 10, 1, 0)) AS tp_inicio_dias_top5,

    COUNT(DISTINCT IF(ordem_toque <= 5 AND dias_antes <= 3, id_atendimento, NULL)) AS atd_final_dias_top5,
    COUNT(DISTINCT IF(ordem_toque <= 5 AND dias_antes BETWEEN 4 AND 10, id_atendimento, NULL)) AS atd_meio_dias_top5,
    COUNT(DISTINCT IF(ordem_toque <= 5 AND dias_antes > 10, id_atendimento, NULL)) AS atd_inicio_dias_top5,

    -- “Este canal foi o last_agd do atendimento?”
    SUM(IF(is_last_agd = 1, 1, 0)) AS tp_is_last_agd,
    COUNT(DISTINCT IF(is_last_agd = 1, id_atendimento, NULL)) AS atd_is_last_agd
  FROM base_tp_influencia
  LEFT JOIN class_mensal c
    ON cpf = c.nu_cpf_paciente
   AND DATE_TRUNC(dt_atendimento, MONTH) = c.inicio_mes_atual_analise
  GROUP BY ALL
),

last_agd_atd AS (
  SELECT
    id_atendimento,
    cpf,
    ANY_VALUE(dt_atendimento) AS dt_atendimento,
    ANY_VALUE(desc_operadora) AS desc_operadora,
    ANY_VALUE(sg_uf_paciente) AS sg_uf_paciente,
    ANY_VALUE(cd_sexo_paciente) AS cd_sexo_paciente,
    ANY_VALUE(faixa_etaria) AS faixa_etaria,
    ANY_VALUE(nm_regional_unidade) AS nm_regional_unidade,
    ANY_VALUE(nm_marca_unidade) AS nm_marca_unidade,
    ANY_VALUE(nm_grupo_mercado_exame) AS nm_grupo_mercado_exame,
    ANY_VALUE(canal_last_agd) AS canal_last_agd,
    ANY_VALUE(subcanal_last_agd) AS subcanal_last_agd,
    ANY_VALUE(tipo_atd_local) AS tipo_atd_local,
    SUM(receita_last_agd) AS receita_last_agd,
    COUNT(*) AS touchpoints_jornada
  FROM base_tp_influencia
  GROUP BY 1, 2
),

last_agd AS (
  SELECT
    dt_atendimento,
    canal_last_agd AS canal,
    subcanal_last_agd AS subcanal,
    desc_operadora,
    sg_uf_paciente,
    cd_sexo_paciente,
    faixa_etaria,
    nm_regional_unidade,
    nm_marca_unidade,
    nm_grupo_mercado_exame,
    tipo_atd_local,
    c.classificacao_paciente_empresa,
    c.classificacao_paciente_marca,
    c.classificacao_paciente_pagamento,
    c.classificacao_paciente_produto,
    c.classificacao_paciente_local,
    "Last Agd" AS atribuicao,
    COUNT(*) AS touch_points,
    COUNT(*) AS atendimentos,
    SUM(receita_last_agd) AS receita,
    COUNT(DISTINCT cpf) AS pacientes,
    NULL AS tp_ordem_1,
    NULL AS tp_ordem_2,
    NULL AS tp_ordem_3,
    NULL AS tp_ordem_4,
    NULL AS tp_ordem_5,
    NULL AS touch_points_top5,
    NULL AS tp_final_tp_top5,
    NULL AS tp_meio_tp_top5,
    NULL AS tp_inicio_tp_top5,
    NULL AS atd_final_tp_top5,
    NULL AS atd_meio_tp_top5,
    NULL AS atd_inicio_tp_top5,
    NULL AS receita_inicio_tp_top5,
    NULL AS receita_meio_tp_top5,
    NULL AS receita_final_tp_top5,
    NULL AS receita_ordem_1,
    NULL AS receita_ordem_2,
    NULL AS receita_ordem_3,
    NULL AS receita_ordem_4,
    NULL AS receita_ordem_5,
    NULL AS tp_final_dias_top5,
    NULL AS tp_meio_dias_top5,
    NULL AS tp_inicio_dias_top5,
    NULL AS atd_final_dias_top5,
    NULL AS atd_meio_dias_top5,
    NULL AS atd_inicio_dias_top5,
    NULL AS tp_is_last_agd,
    NULL AS atd_is_last_agd
  FROM last_agd_atd
  LEFT JOIN class_mensal c
    ON cpf = c.nu_cpf_paciente
   AND DATE_TRUNC(dt_atendimento, MONTH) = c.inicio_mes_atual_analise
  GROUP BY ALL
)

SELECT * FROM data_driven
UNION ALL
SELECT * FROM last_agd
)