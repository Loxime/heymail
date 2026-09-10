<?php

declare(strict_types=1);

use Symfony\Component\Dotenv\Dotenv;

require dirname(__DIR__) . '/vendor/autoload.php';

$envFile = dirname(__DIR__) . '/.env';

if (is_file($envFile)) {
    (new Dotenv())->bootEnv($envFile);
}

$appEnv = $_SERVER['APP_ENV']
    ?? $_ENV['APP_ENV']
    ?? getenv('APP_ENV');

if (
    !is_string($appEnv)
    || $appEnv === ''
) {
    throw new RuntimeException(
        'APP_ENV must be provided when no .env file is available.',
    );
}

$_SERVER['APP_ENV'] = $appEnv;
$_ENV['APP_ENV'] = $appEnv;

$appDebug = $_SERVER['APP_DEBUG']
    ?? $_ENV['APP_DEBUG']
    ?? getenv('APP_DEBUG');

if ($appDebug === false) {
    $appDebug = '0';
}

if (!is_string($appDebug)) {
    throw new RuntimeException(
        'APP_DEBUG must contain a string value.',
    );
}

$debug = filter_var(
    $appDebug,
    FILTER_VALIDATE_BOOL,
    FILTER_NULL_ON_FAILURE,
);

if (!is_bool($debug)) {
    throw new RuntimeException(
        'APP_DEBUG must contain a valid boolean value.',
    );
}

$_SERVER['APP_DEBUG'] = $debug ? '1' : '0';
$_ENV['APP_DEBUG'] = $debug ? '1' : '0';

if ($debug) {
    umask(0000);
}
