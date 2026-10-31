-- opslink 业务库初始化脚本
-- 由 deploy/install_middleware.sh 调用。要求幂等：重复执行不报错。

CREATE DATABASE IF NOT EXISTS `opslink`
  DEFAULT CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE `opslink`;

CREATE TABLE IF NOT EXISTS `links` (
  `id`          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '主键',
  `code`        VARCHAR(16)  NOT NULL COMMENT '短码',
  `url`         VARCHAR(2048) NOT NULL COMMENT '原始长链接',
  `hit_count`   BIGINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '被访问次数',
  `created_at`  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_code` (`code`),
  KEY `idx_created_at` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='短链映射表';
