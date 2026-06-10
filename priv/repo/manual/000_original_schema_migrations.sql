-- Definition found in imported Neon database dump.
-- Not compatible with Ecto migrations used by Ravner.

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    dirty boolean NOT NULL
);

ALTER TABLE public.schema_migrations OWNER TO neondb_owner;

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);

-- State of schema_migrations for 10.06.2026
-- INSERT INTO public.schema_migrations_original (version, dirty)
-- VALUES (4, false);
