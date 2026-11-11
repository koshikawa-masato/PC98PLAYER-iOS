-- No provider access tokens are persisted. Private screenshots expire with reports.
CREATE TABLE auth_transactions (
  state_hash TEXT PRIMARY KEY,
  provider TEXT NOT NULL,
  app_state TEXT NOT NULL,
  challenge TEXT NOT NULL,
  submission_key TEXT NOT NULL,
  browser_hash TEXT NOT NULL,
  provider_verifier TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX auth_transactions_expiry ON auth_transactions(expires_at);
CREATE TABLE grants (
  code_hash TEXT PRIMARY KEY,
  provider TEXT NOT NULL,
  challenge TEXT NOT NULL,
  submission_key TEXT NOT NULL,
  account_json TEXT,
  expires_at INTEGER NOT NULL,
  consumed_by TEXT
);
CREATE INDEX grants_expiry ON grants(expires_at);
CREATE TABLE reports (
  submission_key TEXT PRIMARY KEY,
  receipt TEXT UNIQUE NOT NULL,
  challenge TEXT NOT NULL,
  digest TEXT NOT NULL,
  provider TEXT NOT NULL,
  report_json TEXT NOT NULL,
  account_json TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  result_json TEXT
);
CREATE INDEX reports_delivery ON reports(status, created_at);
CREATE TABLE attachments (
  receipt TEXT NOT NULL REFERENCES reports(receipt) ON DELETE CASCADE,
  part INTEGER NOT NULL,
  content TEXT NOT NULL,
  PRIMARY KEY(receipt, part)
);
CREATE TABLE rate_limits (
  bucket TEXT PRIMARY KEY,
  count INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
