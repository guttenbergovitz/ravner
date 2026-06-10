-- Previous schema_migrations table was not ecto compatible
-- script was executed manually

DROP TABLE IF EXISTS public.schema_migrations;

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);

ALTER TABLE public.schema_migrations OWNER TO ravnerstage;

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);
SQL
