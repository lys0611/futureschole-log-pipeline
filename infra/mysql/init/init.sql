DROP DATABASE IF EXISTS shopdb;
CREATE DATABASE shopdb;
USE shopdb;

CREATE TABLE IF NOT EXISTS push_messages (
    id INT AUTO_INCREMENT PRIMARY KEY,
    payload JSON,
    received_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS users (
    user_id VARCHAR(36) NOT NULL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(100) NOT NULL,
    gender CHAR(1) NOT NULL,
    age INT NOT NULL,
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS users_logs (
    history_id INT AUTO_INCREMENT PRIMARY KEY,
    user_id VARCHAR(36),
    event_type ENUM('CREATED', 'DELETED') NOT NULL,
    event_time DATETIME DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO users (user_id, name, email, gender, age) VALUES
('u1','Alice','alice@example.com','F',30),
('u2','Bob','bob@example.com','M',20),
('u3','Charlie','charlie@example.com','M',40),
('u4','Diana','diana@example.com','F',25);

CREATE TABLE IF NOT EXISTS products (
    id VARCHAR(10) PRIMARY KEY,
    name VARCHAR(255),
    price DECIMAL(10,2),
    category VARCHAR(100)
);

INSERT INTO products (id, name, price, category) VALUES
('101', 'Wireless Earbuds', 79.99, 'Electronics'),
('102', 'Bluetooth Speaker', 49.99, 'Electronics'),
('103', 'Sneakers', 59.99, 'Fashion'),
('104', 'Backpack', 39.99, 'Fashion'),
('105', 'Coffee Mug', 9.99, 'Home'),
('106', 'Gaming Mouse', 29.99, 'Electronics'),
('107', 'Sunglasses', 19.99, 'Fashion'),
('108', 'Laptop Stand', 25.00, 'Electronics'),
('109', 'Gaming Keyboard', 89.99, 'Gaming'),
('110', 'Game Console', 299.00, 'Gaming'),
('111', 'Python Programming Book', 35.00, 'Books'),
('112', 'Science Fiction Novel', 12.99, 'Books'),
('113', 'Fashionable Hat', 15.99, 'Fashion'),
('114', 'Air Fryer', 79.00, 'Home'),
('115', 'Vacuum Cleaner', 99.99, 'Home'),
('116', 'Coffee Machine', 129.99, 'Home'),
('117', 'Jeans', 49.99, 'Fashion'),
('118', 'Smartphone', 699.99, 'Electronics'),
('119', 'Tablet', 399.99, 'Electronics'),
('120', 'Dress', 59.99, 'Fashion'),
('121', 'Gaming Headset', 59.99, 'Gaming'),
('122', 'Cookbook', 24.99, 'Books'),
('123', 'Thriller Novel', 14.99, 'Books'),
('124', 'T-Shirt', 19.99, 'Fashion');

CREATE TABLE IF NOT EXISTS sessions (
    session_id VARCHAR(36) NOT NULL PRIMARY KEY,
    user_id VARCHAR(36) DEFAULT NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    login_time DATETIME(6) DEFAULT NULL,
    logout_time DATETIME(6) DEFAULT NULL,
    last_active DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS reviews (
    review_id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36),
    session_id VARCHAR(36),
    product_id VARCHAR(10),
    rating INT,
    review_time DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    FOREIGN KEY (session_id) REFERENCES sessions(session_id),
    FOREIGN KEY (product_id) REFERENCES products(id)
);

CREATE TABLE IF NOT EXISTS orders (
    order_id VARCHAR(36) PRIMARY KEY,
    user_id VARCHAR(36),
    session_id VARCHAR(36),
    product_id VARCHAR(10),
    price DECIMAL(10,2),
    quantity INT DEFAULT 1,
    order_time DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    FOREIGN KEY (session_id) REFERENCES sessions(session_id),
    FOREIGN KEY (product_id) REFERENCES products(id)
);

CREATE TABLE IF NOT EXISTS search_logs (
    log_id INT AUTO_INCREMENT PRIMARY KEY,
    session_id VARCHAR(36),
    search_query VARCHAR(255),
    searched_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (session_id) REFERENCES sessions(session_id)
);

CREATE TABLE IF NOT EXISTS cart (
    cart_id INT AUTO_INCREMENT PRIMARY KEY,
    session_id VARCHAR(36),
    user_id VARCHAR(36),
    product_id VARCHAR(10),
    quantity INT DEFAULT 1,
    price DECIMAL(10,2),
    added_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FOREIGN KEY (session_id) REFERENCES sessions(session_id),
    FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE,
    FOREIGN KEY (product_id) REFERENCES products(id)
);

CREATE TABLE IF NOT EXISTS cart_logs (
    log_id INT AUTO_INCREMENT PRIMARY KEY,
    cart_id INT,
    session_id VARCHAR(36),
    user_id VARCHAR(36),
    product_id VARCHAR(10),
    old_quantity INT DEFAULT 0,
    new_quantity INT DEFAULT 0,
    price DECIMAL(10,2),
    event_type ENUM('ADDED', 'UPDATED', 'REMOVED', 'CHECKED_OUT'),
    event_time DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (session_id) REFERENCES sessions(session_id),
    FOREIGN KEY (product_id) REFERENCES products(id)
);
