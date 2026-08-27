FROM php:8.2-apache

# ---- System deps + PHP extensions required by MirzaBot / composer.json ----
RUN apt-get update && apt-get install -y --no-install-recommends \
        git unzip cron curl \
        libzip-dev libpng-dev libjpeg-dev libfreetype6-dev \
        libicu-dev libmagickwand-dev libxml2-dev libcurl4-openssl-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        gd zip intl mysqli pdo_mysql bcmath curl \
    && pecl install imagick \
    && docker-php-ext-enable imagick \
    && rm -rf /var/lib/apt/lists/*

# ---- Composer ----
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# ---- Apache config: project root is the document root, enable rewrite ----
RUN a2enmod rewrite headers
COPY docker/apache-vhost.conf /etc/apache2/sites-available/000-default.conf

WORKDIR /var/www/html

# ---- App code ----
COPY . /var/www/html

# ---- PHP deps ----
RUN composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader \
    && mkdir -p /var/www/html/storage \
    && chown -R www-data:www-data /var/www/html

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["entrypoint.sh"]
CMD ["apache2-foreground"]
