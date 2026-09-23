-- CDC 对账 PG 侧的读权限(2026-09-23): CNPG 的指标导出角色 cnpg_metrics_exporter 默认只有 pg_monitor,
-- 对业务 schema 没有 USAGE/SELECT, custom query cdc_rows 会报 permission denied for schema orders。
-- 只给 SELECT(count 需要), 含默认权限让 app 以后新建的表自动覆盖。幂等, 可重复执行。
-- 为什么不进业务仓的 goose 迁移: cnpg_metrics_exporter 是 CNPG 专有角色, 本地 dev 库没有, 迁移会失败;
-- 且这是监控侧权限, 属于基础设施契约, 与 Pigsty 时代的 database-grants SQL 同层。
-- 执行: kubectl -n postgresql exec -i pg-main-1 -c postgres -- psql -U postgres -d ecommerce -v ON_ERROR_STOP=1 < 本文件
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cnpg_metrics_exporter') THEN
    RAISE NOTICE 'cnpg_metrics_exporter 不存在(非 CNPG 库), 跳过';
    RETURN;
  END IF;
  GRANT USAGE ON SCHEMA orders, products TO cnpg_metrics_exporter;
  GRANT SELECT ON ALL TABLES IN SCHEMA orders, products TO cnpg_metrics_exporter;
END $$;
-- 默认权限要以表 owner(app)的身份声明, 放 DO 块外面用 FOR ROLE
ALTER DEFAULT PRIVILEGES FOR ROLE app IN SCHEMA orders   GRANT SELECT ON TABLES TO cnpg_metrics_exporter;
ALTER DEFAULT PRIVILEGES FOR ROLE app IN SCHEMA products GRANT SELECT ON TABLES TO cnpg_metrics_exporter;
