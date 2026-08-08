-- =============================================================================
-- FILE: 01_create_database.sql
-- DESC: Create the toll collection database
-- =============================================================================

DROP DATABASE IF EXISTS toll_collection_db;
CREATE DATABASE toll_collection_db
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE toll_collection_db;
