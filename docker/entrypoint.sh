#!/usr/bin/env bash
set -e

APP_DIR="/var/www/html"
PORT="${PORT:-8080}"

echo "==> Configuring Apache to listen on port ${PORT}"
sed -ri "s/^Listen .*/Listen ${PORT}/" /etc/apache2/ports.conf
sed -i "s/__PORT__/${PORT}/" /etc/apache2/sites-available/000-default.conf

# ---------------------------------------------------------------------------
# Database connection info.
# Prefer Railway's MySQL plugin variable names, fall back to generic DB_* ones.
# ---------------------------------------------------------------------------
DB_HOST="${MYSQLHOST:-${DB_HOST:-localhost}}"
DB_PORT="${MYSQLPORT:-${DB_PORT:-3306}}"
DB_NAME="${MYSQLDATABASE:-${DB_NAME:-railway}}"
DB_USER="${MYSQLUSER:-${DB_USER:-root}}"
DB_PASS="${MYSQLPASSWORD:-${DB_PASS:-}}"

BOT_TOKEN="${BOT_TOKEN:-${APIKEY:-}}"
ADMIN_ID="${ADMIN_ID:-${ADMIN_NUMBER:-}}"
BOT_USERNAME="${BOT_USERNAME:-${USERNAME_BOT:-}}"

# Public domain the bot is served on (no scheme, no trailing slash).
DOMAIN="${DOMAIN:-${RAILWAY_PUBLIC_DOMAIN:-}}"

# A secret Telegram sends back in every webhook request's
# X-Telegram-Bot-Api-Secret-Token header. Railway sits behind multiple proxy
# hops, so Telegram's real source IP never reliably reaches the app — this
# secret-token check (Telegram's own recommended alternative to IP
# allowlisting) replaces IP-based verification and works regardless of how
# many proxies are in front of the container. Derived deterministically from
# the bot token so it's identical across restarts without needing storage.
WEBHOOK_SECRET="$(printf '%s' "${BOT_TOKEN}mirzabot-webhook-secret" | sha256sum | cut -d' ' -f1)"

if [ -z "$BOT_TOKEN" ] || [ -z "$ADMIN_ID" ] || [ -z "$DOMAIN" ]; then
    echo "!! WARNING: BOT_TOKEN, ADMIN_ID and DOMAIN environment variables must be set."
    echo "   The app will start, but the bot will not work until these are configured."
fi

echo "==> Writing config.php from environment variables"
cat > "${APP_DIR}/config.php" <<PHP
<?php
\$request_exec_timeout = null;
\$dbhost = '${DB_HOST}';
\$dbport = '${DB_PORT}';
\$dbname = '${DB_NAME}';
\$usernamedb = '${DB_USER}';
\$passworddb = '${DB_PASS}';
\$options = [
    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    PDO::ATTR_EMULATE_PREPARES => false,
    PDO::MYSQL_ATTR_INIT_COMMAND => "SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci",
];
\$dsn = "mysql:host=\$dbhost;port=\$dbport;dbname=\$dbname;charset=utf8mb4";
try {
    \$pdo = new PDO(\$dsn, \$usernamedb, \$passworddb, \$options);
} catch (\PDOException \$e) {
    error_log("Database connection failed: " . \$e->getMessage());
    die("error: database connection failed");
}
\$APIKEY = '${BOT_TOKEN}';
\$adminnumber = '${ADMIN_ID}';
\$domainhosts = '${DOMAIN}';
\$usernamebot = '${BOT_USERNAME}';
\$webhookSecret = '${WEBHOOK_SECRET}';
?>
PHP
chown www-data:www-data "${APP_DIR}/config.php"

# ---------------------------------------------------------------------------
# Wait for the MySQL database to accept connections. A brand-new MySQL
# service with a fresh volume can take up to a minute to finish its first
# initialization on Railway, so retry generously and log each failed
# connection attempt (mysqli's own warning) instead of hiding it.
# ---------------------------------------------------------------------------
if [ -n "$DB_PASS" ] || [ "$DB_HOST" != "localhost" ]; then
    echo "==> Waiting for MySQL at ${DB_HOST}:${DB_PORT}"
    DB_READY=0
    for i in $(seq 1 60); do
        if php -r "mysqli_report(MYSQLI_REPORT_OFF); \$c = new mysqli('${DB_HOST}', '${DB_USER}', '${DB_PASS}', '${DB_NAME}', ${DB_PORT}); if (\$c->connect_errno) { exit(1); }" 2>/dev/null; then
            echo "==> Database is reachable (after ${i} attempt(s))"
            DB_READY=1
            break
        fi
        sleep 3
    done

    if [ "$DB_READY" != "1" ]; then
        echo "!! Could not reach MySQL at ${DB_HOST}:${DB_PORT} after 3 minutes."
        echo "!! Check that the mysql service is Online in Railway and that MYSQLHOST/MYSQLUSER/MYSQLPASSWORD/MYSQLDATABASE are set correctly on this service."
    fi

    echo "==> Initializing / updating database tables"
    (cd "${APP_DIR}" && php table.php) || echo "!! table.php failed — see the PHP error above for the real reason (bad credentials, unreachable host, or a missing file)."
fi

# ---------------------------------------------------------------------------
# Register the Telegram webhook (safe to call on every boot/redeploy).
# ---------------------------------------------------------------------------
if [ -n "$BOT_TOKEN" ] && [ -n "$DOMAIN" ]; then
    echo "==> Setting Telegram webhook to https://${DOMAIN}/index.php"
    curl -s -F "url=https://${DOMAIN}/index.php" \
        -F "secret_token=${WEBHOOK_SECRET}" \
        "https://api.telegram.org/bot${BOT_TOKEN}/setWebhook" || true
    echo
fi

# ---------------------------------------------------------------------------
# Periodic jobs the bot relies on (expiry checks, notifications, backups...).
# activecron() normally writes a system crontab via the VPS installer; on
# Railway we just run the same URLs on a schedule against localhost.
# ---------------------------------------------------------------------------
echo "==> Installing cron jobs"
cat > /etc/cron.d/mirzabot-cron <<CRON
*/15 * * * * www-data curl -s http://127.0.0.1:${PORT}/cronbot/statusday.php > /dev/null 2>&1
* * * * * www-data curl -s http://127.0.0.1:${PORT}/cronbot/croncard.php > /dev/null 2>&1
* * * * * www-data curl -s http://127.0.0.1:${PORT}/cronbot/NoticationsService.php > /dev/null 2>&1
*/5 * * * * www-data curl -s http://127.0.0.1:${PORT}/cronbot/payment_expire.php > /dev/null 2>&1
* * * * * www-data curl -s http://127.0.0.1:${PORT}/cronbot/sendmessage.php > /dev/null 2>&1
*/3 * * * * www-data curl -s http://127.0.0.1:${PORT}/cronbot/plisio.php > /dev/null 2>&1
* * * * * www-data curl -s http://127.0.0.1:${PORT}/cronbot/activeconfig.php > /dev/null 2>&1
* * * * * www-data curl -s http://127.0.0.1:${PORT}/cronbot/disableconfig.php > /dev/null 2>&1
* * * * * www-data curl -s http://127.0.0.1:${PORT}/cronbot/iranpay1.php > /dev/null 2>&1
0 */5 * * * www-data curl -s http://127.0.0.1:${PORT}/cronbot/backupbot.php > /dev/null 2>&1
*/2 * * * * www-data curl -s http://127.0.0.1:${PORT}/cronbot/gift.php > /dev/null 2>&1
*/30 * * * * www-data curl -s http://127.0.0.1:${PORT}/cronbot/expireagent.php > /dev/null 2>&1
*/15 * * * * www-data curl -s http://127.0.0.1:${PORT}/cronbot/on_hold.php > /dev/null 2>&1
*/2 * * * * www-data curl -s http://127.0.0.1:${PORT}/cronbot/configtest.php > /dev/null 2>&1
*/15 * * * * www-data curl -s http://127.0.0.1:${PORT}/cronbot/uptime_node.php > /dev/null 2>&1
*/15 * * * * www-data curl -s http://127.0.0.1:${PORT}/cronbot/uptime_panel.php > /dev/null 2>&1
CRON
chmod 0644 /etc/cron.d/mirzabot-cron
crontab /etc/cron.d/mirzabot-cron
service cron start

# ---------------------------------------------------------------------------
# Fixing the MPM conflict at build time isn't enough: Railway's runtime layer
# is known to silently re-enable mpm_event on top of php-apache images right
# before the container starts, even when the image itself only ships
# mpm_prefork (this is a documented Railway platform issue, not something
# our Dockerfile controls). So re-apply the fix here, every single boot,
# immediately before Apache actually starts.
# ---------------------------------------------------------------------------
echo "==> Enforcing single Apache MPM (mpm_prefork) before startup"
a2dismod mpm_event mpm_worker >/dev/null 2>&1 || true
rm -f /etc/apache2/mods-enabled/mpm_event.load /etc/apache2/mods-enabled/mpm_event.conf \
      /etc/apache2/mods-enabled/mpm_worker.load /etc/apache2/mods-enabled/mpm_worker.conf
a2enmod mpm_prefork >/dev/null 2>&1 || true
apache2ctl configtest

echo "==> Starting Apache"
exec "$@"
