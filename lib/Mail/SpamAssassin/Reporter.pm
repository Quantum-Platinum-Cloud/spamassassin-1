# Mail::SpamAssassin::Reporter - report a message as spam

# <@LICENSE>
# Copyright 2004 Apache Software Foundation
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# </@LICENSE>

package Mail::SpamAssassin::Reporter;

# Make the main dbg() accessible in our package w/o an extra function
*dbg=\&Mail::SpamAssassin::dbg;

use strict;
use warnings;
use bytes;
use Carp;
use POSIX ":sys_wait_h";

use vars qw{
  @ISA $VERSION
};

@ISA = qw();
$VERSION = 'bogus';	# avoid CPAN.pm picking up razor ver

###########################################################################

sub new {
  my $class = shift;
  $class = ref($class) || $class;
  my ($main, $msg, $options) = @_;

  my $self = {
    'main'		=> $main,
    'msg'		=> $msg,
    'options'		=> $options,
    'conf'		=> $main->{conf},
  };

  bless($self, $class);
  $self;
}

###########################################################################

sub report {
  my ($self) = @_;
  $self->{report_return} = 1;
  $self->{report_available} = 0;

  my $text = $self->{main}->remove_spamassassin_markup($self->{msg});

  $self->{main}->call_plugins("plugin_report", { report => $self, text => \$text, msg => $self->{msg} });

  $self->delete_fulltext_tmpfile();

  if ($self->{report_available} == 0) {
    warn "reporter: no reporting methods available, so couldn't report\n";
  }

  return $self->{report_return};
}

###########################################################################

sub revoke {
  my ($self) = @_;
  $self->{revoke_return} = 0;
  $self->{revoke_available} = 0;

  my $text = $self->{main}->remove_spamassassin_markup($self->{msg});

  $self->{main}->call_plugins("plugin_revoke", { revoke => $self, text => \$text, msg => $self->{msg} });

  return $self->{revoke_return};
}

###########################################################################
# non-public methods.

# Close an fh piped to a process, possibly exiting if the process
# returned nonzero.  thanks to nix /at/ esperi.demon.co.uk for this.
sub close_pipe_fh {
  my ($self, $fh) = @_;

  return if close ($fh);

  my $exitstatus = $?;
  dbg("reporter: raw exit code: $exitstatus");

  if (WIFEXITED ($exitstatus) && (WEXITSTATUS ($exitstatus))) {
    die "reporter: exited with non-zero exit code " . WEXITSTATUS($exitstatus) . "\n";
  }

  if (WIFSIGNALED ($exitstatus)) {
    die "reporter: exited due to signal " . WTERMSIG($exitstatus) . "\n";
  }
}

###########################################################################

sub create_fulltext_tmpfile {
  Mail::SpamAssassin::PerMsgStatus::create_fulltext_tmpfile(@_);
}
sub delete_fulltext_tmpfile {
  Mail::SpamAssassin::PerMsgStatus::delete_fulltext_tmpfile(@_);
}

sub enter_helper_run_mode {
  Mail::SpamAssassin::PerMsgStatus::enter_helper_run_mode(@_);
}
sub leave_helper_run_mode {
  Mail::SpamAssassin::PerMsgStatus::leave_helper_run_mode(@_);
}

1;
