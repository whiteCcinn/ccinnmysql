-- CcinnMysql demo schema (MySQL 5.5+ / MariaDB 10+). Used by integration tests and screenshots.
-- Run with:  mysql -h127.0.0.1 -P13384 -uroot -p < scripts/seed-demo.sql
DROP DATABASE IF EXISTS shop;
CREATE DATABASE shop DEFAULT CHARACTER SET utf8mb4;
USE shop;

CREATE TABLE digits (d TINYINT UNSIGNED NOT NULL PRIMARY KEY) ENGINE=InnoDB;
INSERT INTO digits VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);

CREATE TABLE customers (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  email VARCHAR(190) NOT NULL,
  name VARCHAR(100) NOT NULL,
  city VARCHAR(60) NOT NULL,
  created_at DATETIME NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_email (email),
  KEY idx_city (city)
) ENGINE=InnoDB COMMENT='Registered customers';

INSERT INTO customers (email, name, city, created_at)
SELECT CONCAT('user', a.d * 100 + b.d * 10 + c.d, '@example.com'), CONCAT('Customer ', a.d * 100 + b.d * 10 + c.d),
       ELT(1 + (a.d + b.d + c.d) % 5, 'Kuala Lumpur', 'Penang', 'Johor Bahru', 'Ipoh', 'Kuching'),
       DATE_ADD('2025-01-01', INTERVAL (a.d * 100 + b.d * 10 + c.d) HOUR)
FROM digits a CROSS JOIN digits b CROSS JOIN digits c;

CREATE TABLE orders (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  customer_id INT UNSIGNED NOT NULL,
  status ENUM('new','paid','shipped','cancelled') NOT NULL DEFAULT 'new',
  channel VARCHAR(20) NOT NULL,
  amount DECIMAL(10,2) NOT NULL,
  created_at DATETIME NOT NULL,
  PRIMARY KEY (id),
  KEY idx_customer (customer_id),
  KEY idx_customer_created (customer_id, created_at),
  KEY idx_status (status),
  CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id) REFERENCES customers (id) ON DELETE CASCADE ON UPDATE RESTRICT
) ENGINE=InnoDB COMMENT='Orders (idx_customer is redundant on purpose)';

INSERT INTO orders (customer_id, status, channel, amount, created_at)
SELECT 1 + (a.d * 100 + b.d * 10 + c.d), ELT(1 + (a.d + c.d + e.d) % 4, 'new', 'paid', 'shipped', 'cancelled'),
       ELT(1 + (b.d + e.d) % 3, 'web', 'app', 'store'), ROUND(5 + ((a.d * 7 + b.d * 13 + c.d * 17 + e.d * 19) % 500) + e.d / 10, 2),
       DATE_ADD('2025-01-01', INTERVAL (a.d * 1000 + b.d * 100 + c.d * 10 + e.d) * 37 MINUTE)
FROM digits a CROSS JOIN digits b CROSS JOIN digits c CROSS JOIN (SELECT d FROM digits WHERE d < 2) e;

CREATE TABLE order_items (
  order_id BIGINT UNSIGNED NOT NULL,
  line_no SMALLINT UNSIGNED NOT NULL,
  sku VARCHAR(32) NOT NULL,
  quantity INT NOT NULL,
  price DECIMAL(10,2) NOT NULL,
  PRIMARY KEY (order_id, line_no),
  KEY idx_sku (sku),
  CONSTRAINT fk_items_order FOREIGN KEY (order_id) REFERENCES orders (id) ON DELETE CASCADE
) ENGINE=InnoDB;

INSERT INTO order_items SELECT o.id, l.d + 1, CONCAT('SKU-', (o.id + l.d) % 50), 1 + (o.id % 3), 9.90 + l.d
FROM orders o CROSS JOIN (SELECT d FROM digits WHERE d < 2) l WHERE o.id <= 1000;

CREATE TABLE events_log (
  id BIGINT NOT NULL AUTO_INCREMENT,
  logged_at DATE NOT NULL,
  message VARCHAR(200) NOT NULL,
  PRIMARY KEY (id, logged_at)
) ENGINE=InnoDB
PARTITION BY RANGE (YEAR(logged_at)) (
  PARTITION p2024 VALUES LESS THAN (2025),
  PARTITION p2025 VALUES LESS THAN (2026),
  PARTITION p2026 VALUES LESS THAN (2027),
  PARTITION pmax VALUES LESS THAN MAXVALUE
);
INSERT INTO events_log (logged_at, message)
SELECT DATE_ADD('2024-06-01', INTERVAL (a.d * 100 + b.d * 10 + c.d) DAY), CONCAT('event ', a.d * 100 + b.d * 10 + c.d)
FROM digits a CROSS JOIN digits b CROSS JOIN digits c;

CREATE TABLE legacy_counters (name VARCHAR(40) NOT NULL PRIMARY KEY, hits INT NOT NULL) ENGINE=MyISAM;
INSERT INTO legacy_counters VALUES ('home', 1200), ('search', 845), ('checkout', 97);

CREATE TABLE session_cache (token CHAR(32) NOT NULL PRIMARY KEY, payload VARCHAR(255)) ENGINE=MEMORY;
INSERT INTO session_cache VALUES (LEFT(SHA2('a', 256), 32), 'cart=3'), (LEFT(SHA2('b', 256), 32), 'cart=0');

CREATE TABLE tiny_ids (id TINYINT NOT NULL AUTO_INCREMENT PRIMARY KEY, label VARCHAR(20)) ENGINE=InnoDB AUTO_INCREMENT=120;
INSERT INTO tiny_ids (label) VALUES ('almost'), ('full');

CREATE TABLE audit_no_pk (happened_at DATETIME NOT NULL, note VARCHAR(100)) ENGINE=InnoDB;
INSERT INTO audit_no_pk VALUES (NOW(), 'tables without a primary key are flagged');

CREATE VIEW v_paid_orders AS
  SELECT o.id, c.name, o.amount, o.created_at FROM orders o JOIN customers c ON c.id = o.customer_id WHERE o.status = 'paid';

DELIMITER $$
CREATE PROCEDURE sp_orders_by_city(IN p_city VARCHAR(60))
READS SQL DATA
BEGIN
  SELECT c.city, COUNT(*) AS orders, SUM(o.amount) AS revenue
  FROM orders o JOIN customers c ON c.id = o.customer_id WHERE c.city = p_city GROUP BY c.city;
END$$

CREATE FUNCTION fn_order_total(p_order BIGINT UNSIGNED) RETURNS DECIMAL(12,2)
READS SQL DATA DETERMINISTIC
BEGIN
  DECLARE total DECIMAL(12,2);
  SELECT COALESCE(SUM(quantity * price), 0) INTO total FROM order_items WHERE order_id = p_order;
  RETURN total;
END$$

CREATE TRIGGER trg_orders_bi BEFORE INSERT ON orders FOR EACH ROW
BEGIN
  IF NEW.amount < 0 THEN SET NEW.amount = 0; END IF;
END$$
DELIMITER ;

CREATE EVENT ev_purge_sessions ON SCHEDULE EVERY 1 HOUR DISABLE DO DELETE FROM session_cache;
ANALYZE TABLE customers, orders, order_items, events_log;
