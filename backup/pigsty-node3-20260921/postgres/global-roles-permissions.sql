-- Passwords intentionally omitted by pg_dumpall --no-role-passwords.
--
-- PostgreSQL database cluster dump
--

\restrict TEm0qoKE4CtlmSzyCvPG6Il9ew0OUJj1lVVL2tgO6qvIYyT3nEn9xTBB5Fm3q5s

SET default_transaction_read_only = off;

SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;

--
-- Roles
--

CREATE ROLE app;
ALTER ROLE app WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS;
COMMENT ON ROLE app IS 'ecommerce application user';
CREATE ROLE dbrole_admin;
ALTER ROLE dbrole_admin WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS;
COMMENT ON ROLE dbrole_admin IS 'role for object creation';
CREATE ROLE dbrole_offline;
ALTER ROLE dbrole_offline WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS;
COMMENT ON ROLE dbrole_offline IS 'role for restricted read-only access';
CREATE ROLE dbrole_readonly;
ALTER ROLE dbrole_readonly WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS;
COMMENT ON ROLE dbrole_readonly IS 'role for global read-only access';
CREATE ROLE dbrole_readwrite;
ALTER ROLE dbrole_readwrite WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB NOLOGIN NOREPLICATION NOBYPASSRLS;
COMMENT ON ROLE dbrole_readwrite IS 'role for global read-write access';
CREATE ROLE dbuser_dba;
ALTER ROLE dbuser_dba WITH SUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS;
COMMENT ON ROLE dbuser_dba IS 'pgsql admin user';
CREATE ROLE dbuser_meta;
ALTER ROLE dbuser_meta WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS;
COMMENT ON ROLE dbuser_meta IS 'pigsty admin user';
CREATE ROLE dbuser_monitor;
ALTER ROLE dbuser_monitor WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS;
COMMENT ON ROLE dbuser_monitor IS 'pgsql monitor user';
CREATE ROLE dbuser_view;
ALTER ROLE dbuser_view WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS;
COMMENT ON ROLE dbuser_view IS 'read-only viewer';
CREATE ROLE lyrapass_app;
ALTER ROLE lyrapass_app WITH NOSUPERUSER NOINHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS;
CREATE ROLE lyrapass_owner;
ALTER ROLE lyrapass_owner WITH NOSUPERUSER NOINHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS;
CREATE ROLE openfga;
ALTER ROLE openfga WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS;
CREATE ROLE postgres;
ALTER ROLE postgres WITH SUPERUSER INHERIT CREATEROLE CREATEDB LOGIN REPLICATION BYPASSRLS;
COMMENT ON ROLE postgres IS 'system superuser';
CREATE ROLE replicator;
ALTER ROLE replicator WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN REPLICATION NOBYPASSRLS;
COMMENT ON ROLE replicator IS 'system replicator';
CREATE ROLE umami;
ALTER ROLE umami WITH NOSUPERUSER INHERIT NOCREATEROLE NOCREATEDB LOGIN NOREPLICATION NOBYPASSRLS;

--
-- User Configurations
--

--
-- User Config "dbuser_monitor"
--

ALTER ROLE dbuser_monitor SET log_min_duration_statement TO '1000';
ALTER ROLE dbuser_monitor SET search_path TO 'monitor', 'public';


--
-- Role memberships
--

GRANT dbrole_admin TO app WITH INHERIT TRUE GRANTED BY postgres;
GRANT dbrole_admin TO dbuser_dba WITH INHERIT TRUE GRANTED BY postgres;
GRANT dbrole_admin TO dbuser_meta WITH INHERIT TRUE GRANTED BY postgres;
GRANT dbrole_readonly TO dbrole_readwrite WITH INHERIT TRUE GRANTED BY postgres;
GRANT dbrole_readonly TO dbuser_monitor WITH INHERIT TRUE GRANTED BY postgres;
GRANT dbrole_readonly TO dbuser_view WITH INHERIT TRUE GRANTED BY postgres;
GRANT dbrole_readonly TO replicator WITH INHERIT TRUE GRANTED BY postgres;
GRANT dbrole_readwrite TO dbrole_admin WITH INHERIT TRUE GRANTED BY postgres;
GRANT pg_monitor TO dbrole_admin WITH INHERIT TRUE GRANTED BY postgres;
GRANT pg_monitor TO dbuser_monitor WITH INHERIT TRUE GRANTED BY postgres;
GRANT pg_monitor TO replicator WITH INHERIT TRUE GRANTED BY postgres;






\unrestrict TEm0qoKE4CtlmSzyCvPG6Il9ew0OUJj1lVVL2tgO6qvIYyT3nEn9xTBB5Fm3q5s

--
-- PostgreSQL database cluster dump complete
--

