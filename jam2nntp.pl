#!/usr/bin/perl

use lib '.';

use strict;
use POE qw(Component::Server::NNTP);
use FTN::JAM;
use Data::Dumper;

#use MIME::QuotedPrint;
use MIME::Words qw(encode_mimeword);
use FTN::Address;
use Date::Format;
use Date::Parse;
#use DateTime;
#use DateTime::Format::Mail;
use MIME::Parser;
use Encode;

my %groups;
my %grtype;
my $Address;

unless( $ARGV[0] ) {
  print "Use jam2nntp.pl \"path_to_hpt_config\"\nDefault /usr/local/etc/fido/config\n";
  $ARGV[0] = '/usr/local/etc/fido/config';
}

if ( open F, $ARGV[0] ) {
    while (<F>) {
        if (/^(Netmail|Echo|Bad|Local|Dupe)Area\s+(\S+)\s+(\S+)\s.*?-b\s+Jam/)
        {
            $groups{ lc( 'fido7.' . $2 ) } = $3;
            $grtype{ lc( 'fido7.' . $2 ) } = lc $1;
        }
        if (/^Address\s+([\d:\.\/]+)/) {
            $Address = $1;
        }
    }
    close F;
}

my $nntpd = POE::Component::Server::NNTP->spawn(
    alias   => 'nntpd',
    posting => 1,
    port    => 10119,
    extra_cmds => ['mode']
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
              nntpd_cmd_mode
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

sub nntpd_cmd_mode {
    my ( $kernel, $sender, $client_id, $arg ) = @_[ KERNEL, SENDER, ARG0, ARG1 ];
    my $message = '502 Reading service permanently unavailable';
    if( $arg eq 'READER' ) {
      $message = '200 Posting allowed';  
	}
    $kernel->post( $sender, 'send_to_client', $client_id, $message );
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

#MESSAGE
    print Dumper($text);
    my $parser = new MIME::Parser;
    $parser->decode_headers(1);
    $parser->tmp_to_core(1);

    #  $parser->decode_bodies(1);
    my $entity = $parser->parse_data( join "\n", @$text );
    my $head   = $entity->head;

	my $grouplist = lc $head->get('Newsgroups');
	chomp $grouplist;
	my $ok = 0;

	if( $head->get('Control') ) {
		my $command = $head->get('Control');
		chomp $command;
		if( $command =~ /^cancel\s+(.*)/ ) {
			my $id = $1;
			my $handle = FTN::JAM::OpenMB( $groups{$grouplist} ) or die;
			my $num = searchid( $id, $handle );
			
			FTN::JAM::LockMB( $handle, 10 ) or die;
			my( %header, @subfields, $text );
			FTN::JAM::ReadMessage( $handle, $num, \%header,\@subfields,\$text ) or die;
			$header{Attributes} |= FTN::JAM::Attr::DELETED;
			FTN::JAM::ChangeMessage( $handle, $num, \%header ) or die;
			FTN::JAM::UnlockMB($handle);
			FTN::JAM::CloseMB($handle);
			$ok = 1;
		}
		
	} else {

		my ( $subfields, $nmsubfields, $headerref, $msg ) = rfc2ftn( $head, $entity->bodyhandle );
	
	
#WRITE


		foreach my $group ( split /\s*,\s*/, $grouplist ) {
			my %hr = %$headerref;
			my @sf = @$subfields;
			if( $grtype{$group} eq 'netmail' ) {
				$hr{Attributes} = FTN::JAM::Attr::LOCAL | FTN::JAM::Attr::TYPENET | FTN::JAM::Attr::PRIVATE;
				@sf = ( @sf, @$nmsubfields );
			} else {
				$hr{Attributes} = FTN::JAM::Attr::LOCAL | FTN::JAM::Attr::TYPEECHO;
			}
			print Dumper( \@sf );
			my $handle = FTN::JAM::OpenMB( $groups{$group} ) or die;
			FTN::JAM::LockMB( $handle, 10 ) or die;
			FTN::JAM::AddMessage( $handle, \%hr, \@sf, $msg ) or die;
			FTN::JAM::UnlockMB($handle);
			FTN::JAM::CloseMB($handle);
			$ok = 1;
		}
	}

    $kernel->post( $sender, 'send_to_client', $client_id,
        $ok ? '240 article posted ok' : '441 posting failed' );
    return;
}

sub rfc2ftn {
	my $head = shift;
	my $bodyh = shift;
    my @subfields = ();


    my $subj   = $head->get('Subject');
    chomp $subj;
    Encode::from_to( $subj, $head->mime_attr('content-type.charset'), 'cp866' );
    my $from = $head->get('From');
    chomp $from;
    $from =~ s/\s+<.*//;
    Encode::from_to( $from, $head->mime_attr('content-type.charset'), 'cp866' );
    my $xto = $head->get('X-Comment-To');
    chomp $xto;
    Encode::from_to( $xto, $head->mime_attr('content-type.charset'), 'cp866' );

    my $reply = $head->get('In-Reply-To');
    chomp $reply;
    $reply =~ s/.*\+(.*)@.*/$1/;
    $reply =~ s/=/@/;
    $reply =~ s/\?/</;
    $reply =~ s/\?/>/;
    $reply =~ s/(.*)\./$1 /;


    push @subfields, 6;
    push @subfields, $subj;

    push @subfields, 2;
    push @subfields, $from;

    push @subfields, 4;
    push @subfields, $Address . sprintf( " %08x", time );
    if ($reply) {
        push @subfields, 5;
        push @subfields, $reply;
    }


    my $headerref = {};
    
    $headerref->{DateProcessed} = $headerref->{DateReceived} =
      $headerref->{DateWritten} = FTN::JAM::TimeToLocal( str2time( $head->get('Date') ) );
    
    if( $head->get('Date') =~ /([\+\-]\d{4})\s*$/ ) {
	  my $tz = $1;
	  $tz =~ s/\+//;
      push @subfields, 2000;
      push @subfields, 'TZUTC: ' . $tz;
    }
    

#    $headerref->{Attributes} = FTN::JAM::Attr::LOCAL | FTN::JAM::Attr::TYPEECHO;



#NETMAIL
	my $to;
	my @nmsubfields = ();

	my $nto = $head->get('Reply-To');
	chomp $nto;
	if( $nto ) {
		Encode::from_to( $nto, $head->mime_attr('content-type.charset'), 'cp866' );
		if( $nto =~ /^\s*(.*?)\s*<.*?@(?:p(\d+)\.)?f(\d+)\.n(\d+)\.z(\d+)\.fidonet\.org>/) {
		    push @nmsubfields, 1;
			push @nmsubfields, $5 . ':' . $4 . '/' . $3 . ( $2 ? ('.' . $2) : '' );
			$to = $1;
		}
	} else {
		if( $reply =~ /(\d+:\d+\/\d+(\.\d+))/ ) {
			push @nmsubfields, 1;
			push @nmsubfields, $1;
		}
	}
	push @nmsubfields, 0;
	push @nmsubfields, $Address;

	push @subfields, 3;
	push @subfields, $xto ? $xto : ( $to ? $to : 'All' );    
#	$headerref->{Attributes} = FTN::JAM::Attr::LOCAL | FTN::JAM::Attr::TYPENET | FTN::JAM::Attr::PRIVATE;


#BODY

    my $org = $head->get('Organization');
    chomp $org;
    Encode::from_to( $org, $head->mime_attr('content-type.charset'), 'cp866' );


    my $msg   = $bodyh->as_string;
    Encode::from_to( $msg, $head->mime_attr('content-type.charset'), 'cp866' );
    $msg =~ s/\r\n/\n/g;
    $msg =~ s/\n/\r/g;
    $msg .= "\r--- jam2nntp.pl\r";
    $msg .= " * Origin: " . ( $org ? $org : 'No origin' ) . " ($Address)\r";
    
    return ( \@subfields, \@nmsubfields, $headerref, \$msg );
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

sub searchid {
		my $article = shift;
		my $handle = shift;
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
        return $search;
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

		my $search = searchid( $article, $handle );
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
		$faddr = '<' . $fields{2};
		$faddr =~ s/\s+/./g;
        $faddr .= '@' . $addr->fqdn('org') . '>';
    }
    else {
        $faddr = $fields{4};
    }

    my $date = time2str( "%a, %e %b %Y %X %z", FTN::JAM::LocalToTime( $header->{DateWritten } ) );
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
