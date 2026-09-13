<?php

declare(strict_types=1);

namespace App\MessageHandler;

use App\Entity\WebhookDelivery;
use App\Enum\WebhookDeliveryStatus;
use App\Message\DeliverWebhook;
use App\Webhook\WebhookHttpClient;
use App\Webhook\WebhookRequestFactory;
use Doctrine\ORM\EntityManagerInterface;
use Symfony\Component\Messenger\Attribute\AsMessageHandler;
use Throwable;

#[AsMessageHandler]
final readonly class DeliverWebhookHandler
{
    public function __construct(
        private EntityManagerInterface $entityManager,
        private WebhookRequestFactory $requestFactory,
        private WebhookHttpClient $httpClient,
    ) {
    }

    public function __invoke(
        DeliverWebhook $message,
    ): void {
        $delivery =
            $this->entityManager
                ->find(
                    WebhookDelivery::class,
                    $message->webhookDeliveryId,
                );

        if (
            !$delivery
            instanceof WebhookDelivery
        ) {
            return;
        }

        if (
            $delivery->getStatus()
            !== WebhookDeliveryStatus::PENDING
        ) {
            return;
        }

        $endpoint =
            $delivery->getEndpoint();

        if (!$endpoint->isEnabled()) {
            $delivery->markFailedAttempt(
                'Webhook endpoint is disabled.',
            );

            $this->entityManager
                ->flush();

            return;
        }

        try {
            $request =
                $this
                    ->requestFactory
                    ->create(
                        $delivery,
                        time(),
                    );

            $status =
                $this
                    ->httpClient
                    ->post(
                        $endpoint->getUrl(),
                        $delivery
                            ->getPublicId(),
                        $request,
                    );

            if (
                $status >= 200
                && $status < 300
            ) {
                $delivery
                    ->markSucceeded();

                $this->entityManager
                    ->flush();

                return;
            }

            $delivery
                ->markFailedAttempt(
                    sprintf(
                        'Webhook returned HTTP %d.',
                        $status,
                    ),
                );
        } catch (Throwable $exception) {
            $delivery
                ->markFailedAttempt(
                    $exception->getMessage(),
                );
        }

        $this->entityManager
            ->flush();
    }
}
