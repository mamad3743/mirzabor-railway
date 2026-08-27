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
?>
PHP
chown www-data:www-data "${APP_DIR}/config.php"

# ---------------------------------------------------------------------------
# Wait for the MySQL database to accept connections (Railway MySQL plugin
# can take a few seconds to come up on first deploy).
# ---------------------------------------------------------------------------
if [ -n "$DB_PASS" ] || [ "$DB_HOST" != "localhost" ]; then
    echo "==> Waiting for MySQL at ${DB_HOST}:${DB_PORT}"
    for i in $(seq 1 30); do
        if php -r "new mysqli('${DB_HOST}', '${DB_USER}', '${DB_PASS}', '${DB_NAME}', ${DB_PORT});" 2>/dev/null; then
            echo "==> Database is reachable"
            break
        fi
        sleep 2
    done

    echo "==> Initializing / updating database tables"
    (cd "${APP_DIR}" && php table.php) || echo "!! table.php failed, check DB credentials"
fi

# ---------------------------------------------------------------------------
# Register the Telegram webhook (safe to call on every boot/redeploy).
# ---------------------------------------------------------------------------
if [ -n "$BOT_TOKEN" ] && [ -n "$DOMAIN" ]; then
    echo "==> Setting Telegram webhook to https://${DOMAIN}/index.php"
    curl -s -F "url=https://${DOMAIN}/index.php" \
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

echo "==> Starting Apache"
exec "$@"
