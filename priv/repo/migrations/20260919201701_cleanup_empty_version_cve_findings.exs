defmodule Ravner.Repo.Migrations.CleanupEmptyVersionCveFindings do
  use Ecto.Migration

  def up do
    # 1. Normalize empty/whitespace versions to NULL in domain_tech_evidence
    execute("""
    UPDATE domain_tech_evidence
    SET version = NULL
    WHERE version IS NOT NULL AND trim(version) = '';
    """)

    # 2. Tag implied technologies with proper source
    execute("""
    UPDATE domain_tech_evidence
    SET source = 'wappalyzer:implied'
    WHERE confidence = 50 AND (source = 'wappalyzer' OR source IS NULL);
    """)

    execute("""
    UPDATE domain_tech_evidence
    SET source = 'wappalyzer:direct'
    WHERE (confidence > 50 OR confidence IS NULL) AND source = 'wappalyzer';
    """)

    # 3. Purge bogus CVE findings generated from empty versions in OSV.dev
    execute("""
    DELETE FROM scan_findings
    WHERE detail->>'source' = 'osv.dev'
      AND (detail->>'version' IS NULL OR trim(detail->>'version') = '');
    """)
  end

  def down do
    :ok
  end
end
