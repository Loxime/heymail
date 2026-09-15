<?php

declare(strict_types=1);

namespace App\Console;

use Symfony\Component\EventDispatcher\EventSubscriberInterface;
use Symfony\Component\HttpKernel\Event\RequestEvent;
use Symfony\Component\HttpKernel\KernelEvents;

final readonly class ConsoleOriginSubscriber
    implements EventSubscriberInterface
{
    public function __construct(
        private ConsoleRequestGuard $guard,
    ) {
    }

    public function onKernelRequest(
        RequestEvent $event,
    ): void {
        if (!$event->isMainRequest()) {
            return;
        }

        $request = $event->getRequest();

        if (
            !str_starts_with(
                $request->getPathInfo(),
                '/console/',
            )
        ) {
            return;
        }

        if ($request->isMethodSafe()) {
            return;
        }

        $rejection = $this->guard
            ->rejectCrossOriginMutation(
                $request,
            );

        if ($rejection !== null) {
            $event->setResponse(
                $rejection,
            );
        }
    }

    public static function getSubscribedEvents(): array
    {
        return [
            KernelEvents::REQUEST => [
                'onKernelRequest',
                64,
            ],
        ];
    }
}
