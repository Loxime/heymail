<?php

declare(strict_types=1);

namespace App\Controller;

use App\Suppression\EmailSuppressionService;
use App\Suppression\UnsubscribeTokenCodec;
use Doctrine\DBAL\Connection;
use InvalidArgumentException;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

#[Route('/unsubscribe')]
final readonly class PublicUnsubscribeController
{
    public function __construct(
        private Connection $connection,
        private UnsubscribeTokenCodec $tokens,
        private EmailSuppressionService $suppressions,
    ) {
    }

    #[Route(
        '/{token}',
        name: 'public_unsubscribe_show',
        requirements: [
            'token' => 'u1\.[A-Za-z0-9_-]{32,1000}',
        ],
        methods: ['GET'],
    )]
    public function show(
        string $token,
    ): Response {
        try {
            $decoded = $this->tokens->decode(
                $token,
            );
        } catch (InvalidArgumentException) {
            return $this->notFound();
        }

        $listName = null;

        if (
            $decoded['contactListId']
            !== null
        ) {
            $listName =
                $this->listName(
                    $decoded['workspaceId'],
                    $decoded['contactListId'],
                );

            if ($listName === null) {
                return $this->gone();
            }
        }

        return $this->page(
            token: $token,
            listName: $listName,
            completed: false,
        );
    }

    #[Route(
        '/{token}',
        name: 'public_unsubscribe_submit',
        requirements: [
            'token' => 'u1\.[A-Za-z0-9_-]{32,1000}',
        ],
        methods: ['POST'],
    )]
    public function submit(
        Request $request,
        string $token,
    ): Response {
        try {
            $decoded = $this->tokens->decode(
                $token,
            );
        } catch (InvalidArgumentException) {
            return $this->notFound();
        }

        $contentType =
            $request->getContentTypeFormat();

        if (
            $contentType !== 'form'
            && $request->headers->get(
                'Content-Type',
                '',
            ) !== 'application/x-www-form-urlencoded'
        ) {
            return new Response(
                'Unsupported Media Type',
                Response::HTTP_UNSUPPORTED_MEDIA_TYPE,
            );
        }

        $listName = null;

        if (
            $decoded['contactListId']
            !== null
        ) {
            $listName =
                $this->listName(
                    $decoded['workspaceId'],
                    $decoded['contactListId'],
                );

            if ($listName === null) {
                return $this->gone();
            }
        }

        $oneClick =
            $request->request->get(
                'List-Unsubscribe',
            ) === 'One-Click';

        $scope = $request
            ->request
            ->get(
                'scope',
            );

        if (
            !$oneClick
            && !in_array(
                $scope,
                [
                    'list',
                    'global',
                ],
                true,
            )
        ) {
            return new Response(
                'Invalid unsubscribe request',
                Response::HTTP_UNPROCESSABLE_ENTITY,
            );
        }

        $global =
            !$oneClick
            && $scope === 'global';

        if (
            !$global
            && $decoded['contactListId']
                !== null
        ) {
            $this->suppressions
                ->suppressList(
                    workspaceId:
                        $decoded['workspaceId'],
                    contactListId:
                        $decoded['contactListId'],
                    email:
                        $decoded['email'],
                    reason:
                        'unsubscribe',
                );
        } else {
            $this->suppressions
                ->suppressGlobal(
                    workspaceId:
                        $decoded['workspaceId'],
                    email:
                        $decoded['email'],
                    reason:
                        'unsubscribe',
                );
        }

        return $this->page(
            token: $token,
            listName: $listName,
            completed: true,
        );
    }

    private function listName(
        int $workspaceId,
        int $listId,
    ): ?string {
        $name = $this->connection
            ->fetchOne(
                <<<'SQL'
SELECT name
FROM contact_list
WHERE id = :id
  AND workspace_id = :workspace_id
SQL,
                [
                    'id' => $listId,
                    'workspace_id'
                        => $workspaceId,
                ],
            );

        return is_string($name)
            ? $name
            : null;
    }

    private function page(
        string $token,
        ?string $listName,
        bool $completed,
    ): Response {
        $safeToken =
            htmlspecialchars(
                $token,
                ENT_QUOTES
                | ENT_SUBSTITUTE,
                'UTF-8',
            );

        $safeList = $listName === null
            ? null
            : htmlspecialchars(
                $listName,
                ENT_QUOTES
                | ENT_SUBSTITUTE,
                'UTF-8',
            );

        if ($completed) {
            $content = <<<'HTML'
<h1>Unsubscribed</h1>
<p>Your preference has been saved.</p>
HTML;
        } else {
            $listCopy = $safeList === null
                ? 'these emails'
                : sprintf(
                    'the “%s” list',
                    $safeList,
                );

            $content = sprintf(
                <<<'HTML'
<h1>Unsubscribe</h1>
<p>You can stop receiving %s.</p>
<form method="post">
  <button name="scope" value="list" type="submit">Unsubscribe</button>
</form>
<form method="post">
  <button name="scope" value="global" type="submit">Unsubscribe from all emails</button>
</form>
HTML,
                $listCopy,
            );

            if ($listName === null) {
                $content = sprintf(
                    <<<'HTML'
<h1>Unsubscribe</h1>
<p>You can stop receiving these emails.</p>
<form method="post" action="/unsubscribe/%s">
  <button name="scope" value="global" type="submit">Unsubscribe from all emails</button>
</form>
HTML,
                    $safeToken,
                );
            }
        }

        $html = sprintf(
            <<<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>HeyMail unsubscribe</title>
<style>
body{font-family:system-ui,sans-serif;margin:0;background:#f7f9fb;color:#172033}
main{max-width:560px;margin:12vh auto;padding:32px;background:#fff;border:1px solid #e5e9ef;border-radius:14px}
h1{margin-top:0}
form{margin-top:14px}
button{font:inherit;padding:10px 14px;border:1px solid #c9d2dc;border-radius:8px;background:#fff;cursor:pointer}
</style>
</head>
<body><main>%s</main></body>
</html>
HTML,
            $content,
        );

        $response = new Response(
            $html,
            Response::HTTP_OK,
            [
                'Content-Type'
                    => 'text/html; charset=UTF-8',
                'Cache-Control'
                    => 'no-store',
                'Content-Security-Policy'
                    => "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
                'Referrer-Policy'
                    => 'no-referrer',
                'X-Content-Type-Options'
                    => 'nosniff',
                'X-Frame-Options'
                    => 'DENY',
            ],
        );

        return $response;
    }

    private function notFound(): Response
    {
        return new Response(
            'Not Found',
            Response::HTTP_NOT_FOUND,
        );
    }

    private function gone(): Response
    {
        return new Response(
            'Gone',
            Response::HTTP_GONE,
        );
    }
}
