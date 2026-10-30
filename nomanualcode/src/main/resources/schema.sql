DROP TABLE IF EXISTS person;

CREATE TABLE person (
    id            BIGINT AUTO_INCREMENT PRIMARY KEY,
    first_name    VARCHAR(100) NOT NULL,
    last_name     VARCHAR(100) NOT NULL,
    email         VARCHAR(255) NOT NULL UNIQUE,
    date_of_birth DATE
);
