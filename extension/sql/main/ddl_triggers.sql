/*
  This file creates function to intercept ddl commands executed on the
  main tables of hypertables and convert them to commands that alter
  the coresponding schema structure of hypertables.

  The basic idea is that the main table is a regular sql tables that represents
  the hypertable. DDL changes to that table have corresponding changes on the hypertable.

  The intercepted schema changes work as follows:
    1) a ddl command is intercepted and it is determined whether it's on a hypertable, if not exit.
    2) it is determined whether this is a user or trigger initate command. If it is trigger initiated, exit.
    3) send the corresponding hypertable ddl command to the meta node.

  Because ddl commands cannot be "canceled" without an error, all comands are allowed to succeed. This is
  why the command sent to the meta node always contains a parameter for the node the ddl command was executed on
  (so that the meta node can know that the main table on that node was already modified and does not needed to be 
    modified again).

*/

--Handles ddl create index commands on hypertables
CREATE OR REPLACE FUNCTION _sysinternal.ddl_process_create_index()
  RETURNS event_trigger
 LANGUAGE plpgsql
  AS 
$BODY$
DECLARE
  info record;
  table_oid regclass;
  def TEXT;
  hypertable_row hypertable;
BEGIN
  FOR info IN SELECT * FROM pg_event_trigger_ddl_commands() 
    LOOP
    --get table oid
    SELECT indrelid INTO STRICT table_oid 
    FROM pg_catalog.pg_index 
    WHERE indexrelid = info.objid;

    IF NOT is_main_table(table_oid) OR current_setting('io.ignore_ddl_in_trigger', true) = 'true' THEN
      RETURN;
    END IF; 

    def = _sysinternal.get_general_index_definition(info.objid, table_oid);

    hypertable_row := hypertable_from_main_table(table_oid);

    PERFORM *
        FROM dblink(
          get_meta_server_name(),
          format('SELECT _meta.add_index(%L, %L, %L, %L, %L)', 
            hypertable_row.name,
            hypertable_row.main_schema_name,
            (SELECT relname FROM pg_class WHERE oid = info.objid::regclass),
            def,
            current_database()
        )) AS t(r TEXT);
  END LOOP;
END
$BODY$;

--Handles ddl alter index commands on hypertables
CREATE OR REPLACE FUNCTION _sysinternal.ddl_process_alter_index()
  RETURNS event_trigger
 LANGUAGE plpgsql
  AS 
$BODY$
DECLARE
  info record;
  table_oid regclass;
BEGIN  
  FOR info IN SELECT * FROM pg_event_trigger_ddl_commands() 
    LOOP
      SELECT indrelid INTO STRICT table_oid 
      FROM pg_catalog.pg_index 
      WHERE indexrelid = info.objid;

      IF NOT is_main_table(table_oid) THEN
        RETURN;
      END IF; 

      RAISE EXCEPTION 'ALTER INDEX not supported on hypertable %', table_oid 
      USING ERRCODE = 'IO101';
  END LOOP;
END
$BODY$;


--Handles ddl drop index commands on hypertables
CREATE OR REPLACE FUNCTION _sysinternal.ddl_process_drop_index()
  RETURNS event_trigger
 LANGUAGE plpgsql
  AS 
$BODY$
DECLARE
  info record;
  table_oid regclass;
  hypertable_row hypertable;
BEGIN  
  FOR info IN SELECT * FROM  pg_event_trigger_dropped_objects() 
    LOOP
      SELECT  format('%I.%I', h.main_schema_name, h.main_table_name) INTO table_oid
      FROM hypertable h 
      INNER JOIN hypertable_index i ON (i.hypertable_name = h.name)
      WHERE i.main_schema_name = info.schema_name AND i.main_index_name = info.object_name; 

      IF NOT is_main_table(table_oid) OR current_setting('io.ignore_ddl_in_trigger', true) = 'true' THEN
        RETURN;
      END IF; 

      --TODO: this ignores the concurrently and cascade/restrict modifiers
      

      PERFORM *
          FROM dblink(
            get_meta_server_name(),
            format('SELECT _meta.drop_index(%L, %L, %L)', 
              info.schema_name,
              info.object_name,
              current_database()
          )) AS t(r TEXT);
  END LOOP;
END
$BODY$;

--Handles the following ddl alter table commands on hypertables:
-- ADD COLUMN, DROP COLUMN, ALTER COLUMN SET DEFAULT, ALTER COLUMN DROP DEFAULT, ALTER COLUMN SET/DROP NOT NULL
-- RENAME COLUMN
-- not supported (explicit):
-- ALTER COLUMN SET DATA TYPE
-- Other alter commands also not supported 
CREATE OR REPLACE FUNCTION _sysinternal.ddl_process_alter_table()
  RETURNS event_trigger
 LANGUAGE plpgsql
  AS 
$BODY$
DECLARE
  info record;
  hypertable_row hypertable;
  found_action BOOLEAN;
  att_row pg_attribute;
  rec record;
BEGIN
  FOR info IN SELECT * FROM pg_event_trigger_ddl_commands() 
    LOOP

    --exit if not hypertable or inside trigger
    IF NOT is_main_table(info.objid) OR current_setting('io.ignore_ddl_in_trigger', true) = 'true' THEN
      RETURN;
    END IF; 

    hypertable_row := hypertable_from_main_table(info.objid);
    
    --Try to find what was done. If you can't find it error out.
   found_action = FALSE;

    --was a column added?
    FOR att_row IN 
      SELECT *
       FROM pg_attribute att  
       WHERE attrelid = info.objid AND 
             attnum > 0 AND 
             NOT attisdropped AND 
             att.attnum NOT IN (SELECT f.attnum FROM field f WHERE hypertable_name = hypertable_row.name)
    LOOP
        PERFORM  _sysinternal.create_column_from_attribute(hypertable_row.name, att_row);
        found_action = TRUE;
    END LOOP; 

    --was a column deleted
    FOR rec IN 
      SELECT name 
      FROM field f
      INNER JOIN pg_attribute att ON (attrelid = info.objid AND att.attnum = f.attnum AND attisdropped) --do not match on att.attname here. it gets mangled 
      WHERE hypertable_name = hypertable_row.name 
    LOOP
        PERFORM *
        FROM dblink(
          get_meta_server_name(),
          format('SELECT _meta.drop_field(%L, %L, %L)', 
            hypertable_row.name,
            rec.name,
            current_database()
        )) AS t(r TEXT);
        found_action = TRUE;
    END LOOP; 

    --was a column renamed 
    FOR rec IN 
      SELECT f.name old_name, att.attname new_name 
      FROM field f
      LEFT JOIN pg_attribute att ON (attrelid = info.objid AND att.attnum = f.attnum AND NOT attisdropped)
      WHERE hypertable_name = hypertable_row.name AND f.name IS DISTINCT FROM att.attname
    LOOP
        PERFORM *
        FROM dblink(
          get_meta_server_name(),
          format('SELECT _meta.alter_table_rename_column(%L, %L, %L, %L)', 
            hypertable_row.name,
            rec.old_name,
            rec.new_name,
            current_database()
        )) AS t(r TEXT);
        found_action = TRUE;
    END LOOP;

    --was a colum default changed 
    FOR rec IN 
      SELECT name, _sysinternal.get_default_value_for_attribute(att) AS new_default_value 
      FROM field f
      LEFT JOIN pg_attribute att ON (attrelid = info.objid AND attname = f.name AND att.attnum = f.attnum AND NOT attisdropped)
      WHERE hypertable_name = hypertable_row.name AND _sysinternal.get_default_value_for_attribute(att) IS DISTINCT FROM f.default_value
    LOOP
        PERFORM *
        FROM dblink(
          get_meta_server_name(),
          format('SELECT _meta.alter_column_set_default(%L, %L, %L, %L)', 
            hypertable_row.name,
            rec.name,
            rec.new_default_value,
            current_database()
        )) AS t(r TEXT);
        found_action = TRUE;
    END LOOP;

    --was the not null flag changed? 
    FOR rec IN 
      SELECT name, attnotnull AS new_not_null 
      FROM field f
      LEFT JOIN pg_attribute att ON (attrelid = info.objid AND attname = f.name AND att.attnum = f.attnum AND NOT attisdropped)
      WHERE hypertable_name = hypertable_row.name AND attnotnull != f.not_null
    LOOP
        PERFORM *
        FROM dblink(
          get_meta_server_name(),
          format('SELECT _meta.alter_column_set_not_null(%L, %L, %L, %L)', 
            hypertable_row.name,
            rec.name,
            rec.new_not_null,
            current_database()
        )) AS t(r TEXT);
        found_action = TRUE;
    END LOOP;

    --type changed
    FOR rec IN 
      SELECT name, attnotnull AS new_not_null 
      FROM field f
      LEFT JOIN pg_attribute att ON (attrelid = info.objid AND attname = f.name AND att.attnum = f.attnum AND NOT attisdropped)
      WHERE hypertable_name = hypertable_row.name AND att.atttypid IS DISTINCT FROM f.data_type
    LOOP
      RAISE EXCEPTION 'ALTER TABLE ... ALTER COLUMN SET DATA TYPE  not supported on hypertable %', info.objid::regclass
      USING ERRCODE = 'IO101';
    END LOOP;


    IF NOT found_action THEN
      RAISE EXCEPTION 'Unknown alter table action on %', info.objid::regclass
      USING ERRCODE = 'IO101';
    END IF; 

  END LOOP;
  END
$BODY$;


