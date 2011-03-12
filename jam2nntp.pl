#!/usr/bin/perl

use lib '.';

use strict;
use POE qw(Component::Server::NNTP);
use FTN::JAM;
use Data::Dumper;

#use MIME::QuotedPrint;
use MIME::Words qw(encode_mimeword);
use FTN::Address;
use DateTime;
use DateTime::Format::Mail;
use MIME::Parser;
use Encode;

my %groups;
my $Address;

if ( open F, '/usr/local/etc/fido/config' ) {
    while (<F>) {
        if (/^(?:Netmail|Echo|Bad|Local|Dupe)Area\s+(\S+)\s+(\S+)\s.*?-b\s+Jam/)
        {
            $groups{ lc( 'fido7.' . $1 ) } = $2;
        }
        if (/^Address\s+([\d:\.\/]+)/) {
            $Address = $1;
        }
    }
    close F;
}

my $nntpd = POE::Component::Server::NNTP->spawn(
    alias   => 'nntpd',
    posting => 0,
    port    => 10119,
);

POE::Session->create(
    package_states => [
        'main' => [
            qw(
              _start
              nntpd_connection
              nntpd_disconnected
              nntpd_cmd_post
              nntpd_cmd_ihave
              nntpd_cmd_slave
              nntpd_cmd_newnews
              nntpd_cmd_newgroups
              nntpd_cmd_list
              nntpd_cmd_group
              nntpd_cmd_article
              nntpd_cmd_head
              nntpd_posting
              )
        ],
    ],
    options => { trace => 1, debug => 1 },
);

$poe_kernel->run();
exit 0;

sub _start {
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
    $heap->{clients} = {};
    $kernel->post( 'nntpd', 'register', 'all' );
    return;
}

sub nntpd_connection {
    my ( $kernel, $heap, $client_id ) = @_[ KERNEL, HEAP, ARG0 ];
    $heap->{clients}->{$client_id} = {};
    return;
}

sub nntpd_disconnected {
    my ( $kernel, $heap, $client_id ) = @_[ KERNEL, HEAP, ARG0 ];
    delete $heap->{clients}->{$client_id};
    return;
}

sub nntpd_cmd_slave {
    my ( $kernel, $sender, $client_id ) = @_[ KERNEL, SENDER, ARG0 ];
    $kernel->post( $sender, 'send_to_client', $client_id,
        '202 slave status noted' );
    return;
}

sub nntpd_cmd_post {
    my ( $kernel, $sender, $client_id ) = @_[ KERNEL, SENDER, ARG0 ];
    $kernel->post( $sender, 'send_to_client', $client_id,
        '340 send article to be posted. End with <CR-LF>.<CR-LF>' );
    return;
}

sub nntpd_posting {
    my ( $kernel, $sender, $client_id, $text ) =
      @_[ KERNEL, SENDER, ARG0, ARG2 ];
    my @subfields = ();
    print Dumper($text);
    my $parser = new MIME::Parser;
    $parser->decode_headers(1);

    #  $parser->decode_bodies(1);
    my $entity = $parser->parse_data( join "\n", @$text );
    my $head   = $entity->head;
    my $subj   = $head->get('Subject');
    chomp $subj;
    Encode::from_to( $subj, $head->mime_attr('content-type.charset'), 'cp866' );
    my $from = $head->get('From');
    chomp $from;
    $from =~ s/\s+<.*//;
    Encode::from_to( $from, $head->mime_attr('content-type.charset'), 'cp866' );
    my $to = $head->get('X-Comment-To');
    chomp $to;
    Encode::from_to( $to, $head->mime_attr('content-type.charset'), 'cp866' );

    my $reply = $head->get('In-Reply-To');
    chomp $reply;
    $reply =~ s/.*\+(.*)@.*/$1/;
    $reply =~ s/=/@/;
    $reply =~ s/\?/</;
    $reply =~ s/\?/>/;
    $reply =~ s/(.*)\./$1 /;

    push @subfields, 6;
    push @subfields, $subj;

    #  push @subfields, 0;
    #  push @subfields, $Address;
    push @subfields, 2;
    push @subfields, $from;
    push @subfields, 3;
    push @subfields, $to ? $to : 'All';
    push @subfields, 4;
    push @subfields, $Address . sprintf( " %08x", time );
    if ($reply) {
        push @subfields, 5;
        push @subfields, $reply;
    }

    #  push @subfields, 2000;
    #  push @subfields, 'TZUTC: 0300';
    print Dumper( \@subfields );

    my $headerref = {};
    $headerref->{DateProcessed} = $headerref->{DateReceived} =
      $headerref->{DateWritten} = FTN::JAM::TimeToLocal(time);
    $headerref->{Attributes} = FTN::JAM::Attr::LOCAL | FTN::JAM::Attr::TYPEECHO;

    my $org = $head->get('Organization');
    chomp $org;
    Encode::from_to( $org, $head->mime_attr('content-type.charset'), 'cp866' );

    my $bodyh = $entity->bodyhandle;
    my $msg   = $bodyh->as_string;
    Encode::from_to( $msg, $head->mime_attr('content-type.charset'), 'cp866' );
    $msg =~ s/\r\n/\n/g;
    $msg =~ s/\n/\r/g;
    $msg .= "\r--- jam2nntp.pl\r";
    $msg .= " * Origin: " . ( $org ? $org : 'No origin' ) . " ($Address)\r";

    my $group = lc $head->get('Newsgroups');
    chomp $group;
    my $handle = FTN::JAM::OpenMB( $groups{$group} ) or die;
    FTN::JAM::LockMB( $handle, 10 ) or die;
    FTN::JAM::AddMessage( $handle, $headerref, \@subfields, \$msg ) or die;
    FTN::JAM::UnlockMB($handle);
    FTN::JAM::CloseMB($handle);

    $kernel->post( $sender, 'send_to_client', $client_id,
        '240 article posted ok' );
    return;
}

sub nntpd_cmd_ihave {
    my ( $kernel, $sender, $client_id ) = @_[ KERNEL, SENDER, ARG0 ];
    $kernel->post( $sender, 'send_to_client', $client_id,
        '435 article not wanted' );
    return;
}

sub nntpd_cmd_newnews {
    my ( $kernel, $sender, $client_id ) = @_[ KERNEL, SENDER, ARG0 ];
    $kernel->post( $sender, 'send_to_client', $client_id,
        '230 list of new articles follows' );
    $kernel->post( $sender, 'send_to_client', $client_id, '.' );
    return;
}

sub nntpd_cmd_newgroups {
    my ( $kernel, $sender, $client_id ) = @_[ KERNEL, SENDER, ARG0 ];
    $kernel->post( $sender, 'send_to_client', $client_id,
        '231 list of new newsgroups follows' );
    $kernel->post( $sender, 'send_to_client', $client_id, '.' );
    return;
}

sub nntpd_cmd_list {
    my ( $kernel, $sender, $client_id ) = @_[ KERNEL, SENDER, ARG0 ];
    $kernel->post( $sender, 'send_to_client', $client_id,
        '215 list of newsgroups follows' );
    foreach my $group ( keys %groups ) {
        my $num = 0;

        my $handle = FTN::JAM::OpenMB( $groups{$group} ) or next;
        FTN::JAM::GetMBSize( $handle, \$num ) or die;
        FTN::JAM::CloseMB($handle);
        my $reply = join ' ', $group, $num, 1, 'n';
        $kernel->post( $sender, 'send_to_client', $client_id, $reply );
    }
    $kernel->post( $sender, 'send_to_client', $client_id, '.' );
    return;
}

sub nntpd_cmd_group {
    my ( $kernel, $sender, $client_id, $group ) =
      @_[ KERNEL, SENDER, ARG0, ARG1 ];

    #  print "GROUP $group : $client_id\n";
    unless ( $group and exists $groups{ lc $group } ) {
        $kernel->post( $sender, 'send_to_client', $client_id,
            '411 no such news group' );
        return;
    }
    $group = lc $group;
    my $num    = 0;
    my $handle = $_[HEAP]->{clients}->{$client_id}->{handle};
    if ($handle) {

#	  print "CLOSE $handle " . $_[HEAP]->{clients}->{ $client_id }->{group} . "\n";
        FTN::JAM::CloseMB($handle) if $handle;
    }
    $handle = FTN::JAM::OpenMB( $groups{$group} )
      or die("OpenMB : $group : $groups{$group}");
    FTN::JAM::GetMBSize( $handle, \$num ) or die;
    $_[HEAP]->{clients}->{$client_id} = { group => $group };
    $_[HEAP]->{clients}->{$client_id}->{handle} = $handle;
    $kernel->post( $sender, 'send_to_client', $client_id,
        "211 $num 1 $num $group selected" );
    return;
}

sub nntpd_cmd_article {
    my @params = @_;
    common_article( \@params, 'article' );
}

sub nntpd_cmd_head {

    #	my @params=@_;
    common_article( \@_, 'head' );
    return;
}

sub common_article {
    my $params  = shift;
    my $command = shift;
    my ( $kernel, $sender, $client_id, $article ) =
      @{$params}[ KERNEL, SENDER, ARG0, ARG1 ];

    #print Dumper($groups{$group});

    if (   !$article
        or !defined ${$params}[HEAP]->{clients}->{$client_id}->{group} )
    {
        $kernel->post( $sender, 'send_to_client', $client_id,
            '412 no newsgroup selected' );
        return;
    }

    #  print Dumper(${$params}[HEAP]->{clients}->{ $client_id });
    my $group = ${$params}[HEAP]->{clients}->{$client_id}->{group};

    my $handle = ${$params}[HEAP]->{clients}->{$client_id}->{handle};

#  print "ARTICLE group: $group client: $client_id article: $article handle: $handle\n";
    $article = 1 unless $article;

    if ( $article =~ /^<.*>$/ ) {
        my $num;
        my $size;
        $article =~ s/.*\+(.*)@.*/$1/;
        $article =~ s/=/@/;
        $article =~ s/\?/</;
        $article =~ s/\?/>/;
        $article =~ s/(.*)\./$1 /;
        my $search;

        FTN::JAM::GetMBSize( $handle, \$size ) or die;
        for ( $num = 1 ; $num <= $size ; $num++ ) {
            my ( %header, @subfields, $text );
            FTN::JAM::ReadMessage( $handle, $num, \%header, \@subfields,
                \$text )
              or next;
            my %fields = @subfields;
            if ( $fields{4} eq $article ) {
                $search = $num;
                last;
            }
        }
        if ($search) {
            $article = $search;
        }
        else {
            $kernel->post( $sender, 'send_to_client', $client_id,
                '430 no such article found' );
            return;
        }
    }

    my ( %header, @subfields, $text );
    my $success =
      FTN::JAM::ReadMessage( $handle, $article, \%header, \@subfields, \$text );

    unless ($success) {
        $kernel->post( $sender, 'send_to_client', $client_id,
            '423 no such article number' );
        return;
    }

    my $msg_id = $article;

    my $textsend = '';
    if ( $command eq 'head' ) {

        #		print "head\n";
        $kernel->post( $sender, 'send_to_client', $client_id,
            "221 $msg_id <0> article retrieved - head follow" );
        $textsend = message_header( $group, \%header, \@subfields );
    }
    elsif ( $command eq 'article' ) {

        #		print "article\n";
        $kernel->post( $sender, 'send_to_client', $client_id,
            "220 $msg_id <0> article retrieved - head and body follow" );
        $textsend = message_header( $group, \%header, \@subfields );
        $textsend .= "\n";
        $text =~ s/\r/\n/g;
        $textsend .= $text;
    }

    #	print $textsend;
    my @textsend = split /\n/, $textsend;

    #	print Dumper(\@textsend);
    #	for( @textsend ) {
    #		s/^$/\n/;
    $kernel->post( $sender, 'send_to_client', $client_id, $textsend );

    #    }
    $kernel->post( $sender, 'send_to_client', $client_id, '.' );

    #  }
    return;
}

sub convertid {
    my $id = shift;
    $$id =~ s/<|>/?/g;
    $$id =~ s/@/=/g;
    $$id =~ s/ /./g;
    $$id =~ s/^\.+//;
    $$id =~ s/\.+&//;
    $$id =~ s/\.+/./g;
}

sub message_header {
    my ( $group, $header, $subfields ) = @_;

    my %fields = @$subfields;
    my $subj = encode_mimeword( $fields{6}, 'Q', 'CP866' );

    #	$subj =~ s/\n|\r//g;
    #	print Dumper($subfields);
    my $msgid = $fields{4};
    convertid \$msgid;
    my $refer = $fields{5};
    convertid \$refer;

    $fields{4} =~ s/\s.*//;
    my $faddr;
    my $addr;
    if ( $addr = new FTN::Address( $fields{4} ) ) {
        $faddr = '<' . $addr->fqdn() . '>';
    }
    else {
        $faddr = $fields{4};
    }
    my $dt =
      DateTime->from_epoch(
        epoch => FTN::JAM::LocalToTime( $header->{DateWritten} ) );
    my $date = DateTime::Format::Mail->format_datetime($dt);
    my $head =
        "Newsgroups: $group\n"
      . "Path: localhost\n"
      . "Date: $date\n"
      . "Subject: $subj\n"
      . "From: "
      . $fields{2}
      . " $faddr\n"
      . "Message-ID: <"
      . $group . '+'
      . $msgid
      . "\@localhost>\n"
      . ( $refer
        ? "References: <" . $group . '+' . $refer . "\@localhost>\n"
        : '' )
      . "Content-Type: text/plain; charset=CP866\n"
      . "X-Comment-To: "
      . $fields{3} . "\n";

    return $head;
}
