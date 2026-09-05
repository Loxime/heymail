<?php

declare(strict_types=1);

function requiredEnv(string $name): string
{
    $value = getenv($name);

    if ($value === false || $value === '') {
        throw new RuntimeException(sprintf(
            'Required environment variable %s is missing.',
            $name,
        ));
    }

    return $value;
}

function readSecret(string $envName): string
{
    $path = requiredEnv($envName);

    if (!is_file($path) || !is_readable($path)) {
        throw new RuntimeException(sprintf(
            'Secret file referenced by %s is not readable.',
            $envName,
        ));
    }

    $secret = trim((string) file_get_contents($path));

    if ($secret === '') {
        throw new RuntimeException(sprintf(
            'Secret file referenced by %s is empty.',
            $envName,
        ));
    }

    return $secret;
}

try {
    /*
     * Composer / Symfony Runtime integrity.
     */
    $composerAutoload = '/app/vendor/autoload.php';
    $runtimeAutoload = '/app/vendor/autoload_runtime.php';

    if (!is_readable($composerAutoload)) {
        throw new RuntimeException(
            'Composer autoloader is missing or unreadable.',
        );
    }

    if (!is_readable($runtimeAutoload)) {
        throw new RuntimeException(
            'Symfony runtime autoloader is missing or unreadable.',
        );
    }

    require_once $composerAutoload;

    if (!class_exists(\Symfony\Component\Runtime\SymfonyRuntime::class)) {
        throw new RuntimeException(
            'Symfony Runtime class cannot be autoloaded.',
        );
    }

    /*
     * Docker runtime policy.
     *
     * Production containers must not depend on a .env file.
     */
    $runtimeOptions = json_decode(
        requiredEnv('APP_RUNTIME_OPTIONS'),
        true,
        512,
        JSON_THROW_ON_ERROR,
    );

    if (($runtimeOptions['disable_dotenv'] ?? null) !== true) {
        throw new RuntimeException(
            'Symfony dotenv loading is not explicitly disabled.',
        );
    }

    /*
     * Runtime secrets.
     */
    readSecret('APP_SECRET_FILE');
    $databasePassword = readSecret('DB_PASSWORD_FILE');

    /*
     * Boot the actual Symfony Kernel.
     *
     * This catches application configuration errors which a pure PHP/PDO
     * healthcheck would miss.
     */
    $appEnv = requiredEnv('APP_ENV');
    $appDebug = requiredEnv('APP_DEBUG') === '1';

    $kernel = new \App\Kernel($appEnv, $appDebug);
    $kernel->boot();

    /*
     * PostgreSQL runtime identity.
     */
    $databaseHost = requiredEnv('DB_HOST');
    $databasePort = requiredEnv('DB_PORT');
    $databaseName = requiredEnv('DB_NAME');
    $databaseUser = requiredEnv('DB_USER');

    if ($databaseUser !== 'heymail_app') {
        throw new RuntimeException(
            'Unexpected PostgreSQL runtime role.',
        );
    }

    $dsn = sprintf(
        'pgsql:host=%s;port=%s;dbname=%s',
        $databaseHost,
        $databasePort,
        $databaseName,
    );

    $pdo = new PDO(
        $dsn,
        $databaseUser,
        $databasePassword,
        [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_TIMEOUT => 3,
        ],
    );

    $currentUser = $pdo
        ->query('SELECT current_user')
        ->fetchColumn();

    if ($currentUser !== 'heymail_app') {
        throw new RuntimeException(
            'PostgreSQL connection does not use heymail_app.',
        );
    }

    $result = $pdo
        ->query('SELECT 1')
        ->fetchColumn();

    if ((int) $result !== 1) {
        throw new RuntimeException(
            'Unexpected PostgreSQL healthcheck result.',
        );
    }

    $kernel->shutdown();

    exit(0);
} catch (Throwable $exception) {
    fwrite(
        STDERR,
        'HeyMail API healthcheck failed: '
        . $exception->getMessage()
        . PHP_EOL,
    );

    exit(1);
}
