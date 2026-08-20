CREATE TABLE IF NOT EXISTS analytics.smoke (id UInt64, v String) ENGINE = MergeTree ORDER BY id;
INSERT INTO analytics.smoke VALUES (1, 'ok');
SELECT * FROM analytics.smoke;
