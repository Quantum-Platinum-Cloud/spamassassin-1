# Mail message object, used by SpamAssassin.  This was written to eliminate, as
# much as possible, SpamAssassin's dependency on Mail::Audit and the
# Mail::Internet, Net::SMTP, etc. module set it requires.
#
# This is more efficient (less modules, dependencies and unused code loaded),
# and fixes some bugs found in Mail::Audit, as well as working around some
# side-effects of features of Mail::Internet that we don't use.  It's also more
# lenient about the incoming message, in the spirit of the IETF dictum 'be
# liberal in what you accept'.
#
# A regexp from Mail::Header is used.  Mail::Header is Copyright (c) 1995-2001
# Graham Barr <gbarr@pobox.com>. All rights reserved.  This program is free
# software; you can redistribute it and/or modify it under the same terms as
# Perl itself.
#
package Mail::SpamAssassin::NoMailAudit;

use Mail::SpamAssassin::Message;
use Fcntl qw(:DEFAULT :flock);

@Mail::SpamAssassin::NoMailAudit::ISA = (
        'Mail::SpamAssassin::Message'
);

# ---------------------------------------------------------------------------

sub new {
  my $class = shift;
  my %opts = @_;

  my $self = $class->SUPER::new();

  $self->{is_spamassassin_wrapper_object} = 1;
  $self->{has_spamassassin_methods} = 1;
  $self->{headers} = { };
  $self->{header_order} = [ ];

  # an option: SpamAssassin can set this appropriately.
  # undef means 'figure it out yourself'.
  $self->{add_From_line} = $opts{add_From_line};

  # default: always add it
  if (!defined $self->{add_From_line}) {
    $self->{add_From_line} = 1;
  }

  bless ($self, $class);

  if (defined $opts{'data'}) {
    $self->{textarray} = $opts{data};
  } else {
    $self->{textarray} = $self->read_text_array_from_stdin();
  }

  $self->parse_headers();
  return $self;
}

# ---------------------------------------------------------------------------

sub get_mail_object {
  my ($self) = @_;
  return $self;
}

# ---------------------------------------------------------------------------

sub read_text_array_from_stdin {
  my ($self) = @_;

  my @ary = ();
  while (<STDIN>) {
    push (@ary, $_);
    /^\r*$/ and last;
  }

  push (@ary, (<STDIN>));
  close STDIN;

  $self->{textarray} = \@ary;
}

# ---------------------------------------------------------------------------

sub parse_headers {
  my ($self) = @_;
  local ($_);

  $self->{headers} = { };
  $self->{header_order} = [ ];
  my ($prevhdr, $hdr, $val, $entry);

  while (defined ($_ = shift @{$self->{textarray}})) {
    # warn "JMD $_";
    if (/^\r*$/) { last; }

    $entry = $hdr = $val = undef;

    if (/^\s/) {
      if (defined $prevhdr) {
	$hdr = $prevhdr; $val = $_;
        $val =~ s/\r+\n/\n/gs;          # trim CRs, we don't want them
	$entry = $self->{headers}->{$hdr};
	$entry->{$entry->{count} - 1} .= $val;
	next;

      } else {
	$hdr = "X-Mail-Format-Warning";
	$val = "No previous line for continuation: $_";
	$entry = $self->_get_or_create_header_object ($hdr);
	$entry->{added} = 1;
      }

    } elsif (/^From /) {
      $self->{from_line} = $_;
      next;

    } elsif (/^([^\x00-\x20\x7f-\xff:]+):(.*)$/) {
      $hdr = $1; $val = $2;
      $val =~ s/\r+//gs;          # trim CRs, we don't want them
      $entry = $self->_get_or_create_header_object ($hdr);
      $entry->{original} = 1;

    } else {
      $hdr = "X-Mail-Format-Warning";
      $val = "Bad RFC2822 header formatting in $_";
      $entry = $self->_get_or_create_header_object ($hdr);
      $entry->{added} = 1;
    }

    $self->_add_header_to_entry ($entry, $hdr, $val);
    $prevhdr = $hdr;
  }
}

sub _add_header_to_entry {
  my ($self, $entry, $hdr, $line) = @_;

  # ensure we have line endings
  $line .= "\n" unless $line =~ /\n$/;

  $entry->{$entry->{count}} = $line;
  push (@{$self->{header_order}}, $hdr.":".$entry->{count});
  $entry->{count}++;
}

sub _get_or_create_header_object {
  my ($self, $hdr) = @_;

  if (!defined $self->{headers}->{$hdr}) {
    $self->{headers}->{$hdr} = {
              'count' => 0,
              'added' => 0,
              'original' => 0
    };
  }
  return $self->{headers}->{$hdr};
}

# ---------------------------------------------------------------------------

sub get_header {
  my ($self, $hdr) = @_;

  my $entry = $self->{headers}->{$hdr};

  if (!wantarray) {
    if (!defined $entry || $entry->{count} < 1) { return undef; }
    return $entry->{0};

  } else {
    if (!defined $entry || $entry->{count} < 1) { return ( ); }
    my @ret = ();
    foreach my $i (0 .. ($entry->{count}-1)) { push (@ret, $entry->{$i}); }
    return @ret;
  }
}

sub put_header {
  my ($self, $hdr, $text) = @_;

  my $entry = $self->_get_or_create_header_object ($hdr);
  $self->_add_header_to_entry ($entry, $hdr, $text);
  if (!$entry->{original}) { $entry->{added} = 1; }
}

sub get_all_headers {
  my ($self) = @_;

  my @lines = ();
  # warn "JMD".join (' ', caller);

  if (!defined ($self->{add_From_line}) || $self->{add_From_line} == 1) {
    my $from = $self->{from_line};
    if (!defined $from) {
      my $f = $self->get_header("From"); $f ||= "spamassassin\@localhost\n";
      chomp ($f);

      $f =~ s/^.*?<(.+)>\s*$/$1/g               # Foo Blah <jm@foo>
          or $f =~ s/^(.+)\s\(.*?\)\s*$/$1/g;   # jm@foo (Foo Blah)
      $from = "From $f  ".(scalar localtime(time))."\n";
    }
    push (@lines, $from);
  }

  foreach my $hdrcode (@{$self->{header_order}}) {
    $hdrcode =~ /^([^:]+):(\d+)$/ or next;

    my $hdr = $1;
    my $num = $2;
    my $entry = $self->{headers}->{$hdr};
    next unless defined($entry);

    my $text = $hdr.": ".$entry->{$num};
    if ($text !~ /\n$/s) { $text .= "\n"; }
    push (@lines, $text);
  }

  if (wantarray) {
    return @lines;
  } else {
    return join ('', @lines);
  }
}

sub replace_header {
  my ($self, $hdr, $text) = @_;

  if (!defined $self->{headers}->{$hdr}) {
    return $self->put_header($hdr, $text);
  }

  $self->{headers}->{$hdr}->{0} = $text;
}

sub delete_header {
  my ($self, $hdr) = @_;

  if (defined $self->{headers}->{$hdr}) {
    my @neworder = ();
    foreach my $hdrcode (@{$self->{header_order}}) {
      next if ($hdrcode =~ /^${hdr}:/);
      push (@neworder, $hdrcode);
    }
    @{$self->{header_order}} = @neworder;

    delete $self->{headers}->{$hdr};
  }
}

sub get_body {
  my ($self) = @_;
  return $self->{textarray};
}

sub replace_body {
  my ($self, $aryref) = @_;
  $self->{textarray} = $aryref;
}

# ---------------------------------------------------------------------------
# bonus, not-provided-in-Mail::Audit methods.

sub as_string {
  my ($self) = @_;
  return join ('', $self->get_all_headers()) . "\n" .
                join ('', @{$self->get_body()});
}

# ---------------------------------------------------------------------------
# Mail::Audit emulation methods.

sub get { shift->get_header(@_); }
sub header { shift->get_all_headers(@_); }

sub body {
  my ($self) = shift;
  my $replacement = shift;

  if (defined $replacement) {
    $self->replace_body ($replacement);
  } else {
    return $self->get_body();
  }
}

sub ignore {
  my ($self) = @_;
  exit (0) unless $self->{noexit};
}

sub print {
  my ($self, $fh) = @_;
  print $fh $self->as_string();
}

# ---------------------------------------------------------------------------

sub accept {
  my $self = shift;
  my $file = shift;

  # determine location of mailspool
  if ($ENV{'MAIL'}) {
    $file = $ENV{'MAIL'};
  } elsif (-d "/var/spool/mail/") {
    $file = "/var/spool/mail/" . getpwuid($>);
  } elsif (-d "/var/mail/") {
    $file = "/var/mail/" . getpwuid($>);
  } else {
    die('Could not determine mailspool location for your system.  Try setting $MAIL in the environment.');
  }

  # some bits of code from Mail::Audit here:

  if (exists $self->{accept}) {
    return $self->{accept}->();
  }

  # we don't support maildir or qmail here yet. use the real Mail::Audit
  # for those.

  # note that we cannot use fcntl() locking portably from perl. argh!
  # if this is an issue, we will have to enforce use of procmail for
  # local delivery to mboxes.

  {
    my $gotlock = $self->dotlock_lock ($file);
    my $nodotlocking = 0;

    if (!defined $gotlock) {
      # dot-locking not supported here (probably due to file permissions
      # on the mailspool dir).  just use flock().
      $nodotlocking = 1;
    }

    local $SIG{TERM} = sub { $self->dotlock_unlock (); die "killed"; };
    local $SIG{INT} = sub { $self->dotlock_unlock (); die "killed"; };

    if ($gotlock || $nodotlocking) {
      if (!open (MBOX, ">>$file")) {
        die "Couldn't open $file: $!";
      }

      flock(MBOX, LOCK_EX) or warn "failed to lock $file: $!";
      print MBOX $self->as_string();
      flock(MBOX, LOCK_UN) or warn "failed to unlock $file: $!";
      close MBOX;

      if (!$nodotlocking) {
        $self->dotlock_unlock ();
      }

      if (!$self->{noexit}) { exit 0; }
      return;

    } else {
      die "Could not lock $file: $!";
    }
  }
}

sub dotlock_lock {
  my ($self, $file) = @_;

  my $lockfile = $file.".lock";
  my $locktmp = $file.".lk.$$.".time();
  my $gotlock = 0;
  my $retrylimit = 10;

  if (!sysopen (LOCK, $locktmp, O_WRONLY | O_CREAT | O_EXCL, 0644)) {
    #die "lock $file failed: create $locktmp: $!";
    $self->{dotlock_not_supported} = 1;
    return;
  }

  print LOCK "$$\n";
  close LOCK or die "lock $file failed: write to $locktmp: $!";

  for ($retries = 0; $retries < $retrylimit; $retries++) {
    if ($retries > 0) {
      my $sleeptime = $retries > 12 ? 60 : 5*$retries;
      sleep ($sleeptime);
    }

    if (!link ($locktmp, $lockfile)) { next; }

    # sanity: we should always be able to see this
    my @tmpstat = lstat ($locktmp);
    if (!defined $tmpstat[3]) { die "lstat $locktmp failed"; }

    # sanity: see if the link() succeeded
    @lkstat = lstat ($lockfile);
    if (!defined $lkstat[3]) { next; }	# link() failed

    # sanity: if the lock succeeded, the dev/ino numbers will match
    if ($tmpstat[0] == $lkstat[0] && $tmpstat[1] == $lkstat[1]) {
      unlink $locktmp;
      $self->{dotlock_locked} = $lockfile;
      $gotlock = 1; last;
    }
  }

  return $gotlock;
}

sub dotlock_unlock {
  my ($self) = @_;

  if ($self->{dotlock_not_supported}) { return; }

  my $lockfile = $self->{dotlock_locked};
  if (!defined $lockfile) { die "no dotlock_locked"; }
  unlink $lockfile or warn "unlink $lockfile failed: $!";
}

# ---------------------------------------------------------------------------

sub reject {
  my $self = shift;
  $self->_proxy_to_mail_audit ('reject', @_);
}

sub resend {
  my $self = shift;
  $self->_proxy_to_mail_audit ('resend', @_);
}

# ---------------------------------------------------------------------------

sub _proxy_to_mail_audit {
  my $self = shift;
  my $method = shift;
  my $ret;

  my @textary = split (/^/m, $self->as_string());

  eval {
    require Mail::Audit;

    my %opts = ( 'data' => \@textary );
    if (exists $self->{noexit}) { $opts{noexit} = $self->{noexit}; }
    if (exists $self->{loglevel}) { $opts{loglevel} = $self->{loglevel}; }
    if (exists $self->{log}) { $opts{log} = $self->{log}; }

    my $audit = new Mail::Audit (%opts);

    if ($method eq 'accept') {
      $ret = $audit->accept (@_);
    } elsif ($method eq 'reject') {
      $ret = $audit->reject (@_);
    } elsif ($method eq 'resend') {
      $ret = $audit->resend (@_);
    }
  };

  if ($@) {
    warn "spamassassin: $method() failed, Mail::Audit ".
            "module could not be loaded: $@";
    return undef;
  }

  return $ret;
}

# ---------------------------------------------------------------------------

# does not need to be called it seems.  still, keep it here in case of
# emergency.
sub finish {
  my $self = shift;
  delete $self->{textarray};
  foreach my $key (keys %{$self->{headers}}) {
    delete $self->{headers}->{$key};
  }
  delete $self->{headers};
  delete $self->{mail_object};
}

1;
