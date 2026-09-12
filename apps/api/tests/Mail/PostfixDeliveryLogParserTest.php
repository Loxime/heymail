<?php

declare(strict_types=1);

namespace App\Tests\Mail;

use App\Enum\OutboundMessageEventType;
use App\Mail\PostfixDeliveryLogParser;
use PHPUnit\Framework\TestCase;

final class PostfixDeliveryLogParserTest extends TestCase
{
    public function testParsesSuccessfulDelivery(): void
    {
        $parser = new PostfixDeliveryLogParser(
            'heymail.test',
        );

        self::assertNull(
            $parser->consume(
                'postfix/qmgr[1]: ABC123: '
                . 'from=<bounce+42@heymail.test>, '
                . 'size=100, nrcpt=1',
            ),
        );

        $feedback = $parser->consume(
            'postfix/smtp[2]: ABC123: '
            . 'to=<user@success.test>, '
            . 'relay=fake-mx-success, '
            . 'dsn=2.0.0, status=sent '
            . '(250 2.0.0 Message accepted)',
        );

        self::assertNotNull(
            $feedback,
        );

        self::assertSame(
            42,
            $feedback->outboundMessageId,
        );

        self::assertSame(
            OutboundMessageEventType::DELIVERED,
            $feedback->type,
        );

        self::assertSame(
            '2.0.0',
            $feedback->smtpStatus,
        );
    }

    public function testParsesTemporaryAndPermanentFailures(): void
    {
        $parser = new PostfixDeliveryLogParser(
            'heymail.test',
        );

        $parser->consume(
            'postfix/cleanup[1]: DEF456: '
            . 'message-id=<heymail-99@heymail.test>',
        );

        $temporary = $parser->consume(
            'postfix/smtp[2]: DEF456: '
            . 'to=<user@tempfail.test>, '
            . 'relay=fake-mx-tempfail, '
            . 'dsn=4.1.1, status=deferred '
            . '(450 4.1.1 Temporary recipient failure)',
        );

        self::assertNotNull(
            $temporary,
        );

        self::assertSame(
            OutboundMessageEventType::TEMPFAIL,
            $temporary->type,
        );

        $permanent = $parser->consume(
            'postfix/smtp[3]: DEF456: '
            . 'to=<user@permfail.test>, '
            . 'relay=fake-mx-permfail, '
            . 'dsn=5.1.1, status=bounced '
            . '(550 5.1.1 Recipient rejected)',
        );

        self::assertNotNull(
            $permanent,
        );

        self::assertSame(
            OutboundMessageEventType::BOUNCED,
            $permanent->type,
        );
    }

    public function testRedactsRecipientFromRemoteDiagnostic(): void
    {
        $parser = new PostfixDeliveryLogParser(
            'heymail.test',
        );

        $parser->consume(
            'postfix/qmgr[1]: REDACT1: '
            . 'from=<bounce+77@heymail.test>, '
            . 'size=100, nrcpt=1',
        );

        $feedback = $parser->consume(
            'postfix/smtp[2]: REDACT1: '
            . 'to=<secret@example.test>, '
            . 'relay=mx, '
            . 'dsn=5.1.1, status=bounced '
            . '(550 secret@example.test rejected)',
        );

        self::assertNotNull(
            $feedback,
        );

        self::assertStringNotContainsString(
            'secret@example.test',
            strtolower(
                $feedback->detail,
            ),
        );

        self::assertStringContainsString(
            '[recipient]',
            $feedback->detail,
        );
    }

    public function testIgnoresUnrelatedMail(): void
    {
        $parser = new PostfixDeliveryLogParser(
            'heymail.test',
        );

        self::assertNull(
            $parser->consume(
                'postfix/qmgr[1]: OTHER1: '
                . 'from=<someone@example.com>, '
                . 'size=100, nrcpt=1',
            ),
        );

        self::assertNull(
            $parser->consume(
                'postfix/smtp[2]: OTHER1: '
                . 'to=<user@success.test>, '
                . 'dsn=2.0.0, status=sent '
                . '(250 OK)',
            ),
        );
    }
}
