<?php

declare(strict_types=1);

namespace App\Tests\Mail;

use App\Mail\EmailAddress;
use App\Mail\OutboundEmailPayload;
use InvalidArgumentException;
use PHPUnit\Framework\TestCase;

final class OutboundEmailPayloadTest extends TestCase
{
    public function testTransactionalPayloadRoundTrip(): void
    {
        $payload = new OutboundEmailPayload(
            from: new EmailAddress(
                'sender@heymail.test',
                'HeyMail',
            ),
            to: [
                new EmailAddress(
                    'recipient@success.test',
                    'Recipient',
                ),
            ],
            subject: 'Transactional email',
            textPart: 'Plain text body.',
            htmlPart: '<p>HTML body.</p>',
            replyTo: new EmailAddress(
                'reply@heymail.test',
            ),
        );

        self::assertEquals(
            $payload,
            OutboundEmailPayload::fromArray(
                $payload->toArray(),
            ),
        );
    }

    public function testMultipleRecipientsAreAccepted(): void
    {
        $payload = new OutboundEmailPayload(
            from: new EmailAddress(
                'sender@heymail.test',
            ),
            to: [
                new EmailAddress(
                    'first@success.test',
                ),
                new EmailAddress(
                    'second@success.test',
                ),
            ],
            subject: 'Two recipients',
            textPart: 'Body',
        );

        self::assertCount(
            2,
            $payload->to,
        );
    }

    public function testDuplicateRecipientsAreRejected(): void
    {
        $this->expectException(
            InvalidArgumentException::class,
        );

        new OutboundEmailPayload(
            from: new EmailAddress(
                'sender@heymail.test',
            ),
            to: [
                new EmailAddress(
                    'recipient@success.test',
                ),
                new EmailAddress(
                    'RECIPIENT@success.test',
                ),
            ],
            subject: 'Duplicate',
            textPart: 'Body',
        );
    }

    public function testContentIsRequired(): void
    {
        $this->expectException(
            InvalidArgumentException::class,
        );

        new OutboundEmailPayload(
            from: new EmailAddress(
                'sender@heymail.test',
            ),
            to: [
                new EmailAddress(
                    'recipient@success.test',
                ),
            ],
            subject: 'No content',
        );
    }

    public function testSubjectInjectionIsRejected(): void
    {
        $this->expectException(
            InvalidArgumentException::class,
        );

        new OutboundEmailPayload(
            from: new EmailAddress(
                'sender@heymail.test',
            ),
            to: [
                new EmailAddress(
                    'recipient@success.test',
                ),
            ],
            subject: "Hello\r\nBcc: attacker@example.test",
            textPart: 'Body',
        );
    }

    public function testUnexpectedSerializedFieldIsRejected(): void
    {
        $this->expectException(
            InvalidArgumentException::class,
        );

        OutboundEmailPayload::fromArray([
            'from' => [
                'email' => 'sender@heymail.test',
            ],
            'to' => [
                [
                    'email' => 'recipient@success.test',
                ],
            ],
            'subject' => 'Subject',
            'text' => 'Body',
            'admin' => true,
        ]);
    }
}
