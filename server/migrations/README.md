Migrations are append-only. Once a file may have run anywhere (including prod), never edit it:
add the next NNN_description.sql instead. migrate() records each file's SHA-256 and refuses to
start if an applied file changed.
