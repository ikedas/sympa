# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id$

# Sympa - SYsteme de Multi-Postage Automatique
#
# Copyright (c) 1997, 1998, 1999 Institut Pasteur & Christophe Wolfhugel
# Copyright (c) 1997, 1998, 1999, 2000, 2001, 2002, 2003, 2004, 2005,
# 2006, 2007, 2008, 2009, 2010, 2011 Comite Reseau des Universites
# Copyright (c) 2011, 2012, 2013, 2014, 2015, 2016, 2017 GIP RENATER
# Copyright 2018 The Sympa Community. See the AUTHORS.md file at the
# top-level directory of this distribution and at
# <https://github.com/sympa-community/sympa.git>.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package Sympa::Spool::Moderation;

use strict;
use warnings;

use Conf;
use Sympa::Archive;    # for html_format()
use Sympa::Tools::File;

use base qw(Sympa::Spool::Held);    # Derived class.

sub _directories {
    return {
        directory           => $Conf::Conf{'queuemod'},
        bad_directory       => $Conf::Conf{'queuemod'} . '/bad',
        html_root_directory => $Conf::Conf{'viewmail_dir'},
        html_base_directory => $Conf::Conf{'viewmail_dir'} . '/mod',
    };
}

sub _filter {
    my $self     = shift;
    my $metadata = shift;

    # Compat. <= 6.2.36.
    $metadata->{validated_by} = 'nobody'
        if $metadata
        and $metadata->{validated_by}
        and $metadata->{validated_by} eq '.distribute';

    return $self->SUPER::_filter($metadata);
}

sub _load {
    my $self = shift;

    my $metadatas = $self->SUPER::_load();
    my %mtime     = map {
        ($_ => Sympa::Tools::File::get_mtime($self->{directory} . '/' . $_))
    } @$metadatas;
    return [sort { $mtime{$a} <=> $mtime{$b} } @$metadatas];
}

use constant _marshal_format => '%s@%s_%s%s%s';
use constant _marshal_keys   => [
    qw(localpart domainpart AUTHKEY
        validated_by quiet)
];
use constant _marshal_regexp => qr{\A
    ([^\s\@]+) \@ ([-.\w]+) _ ([\da-f]+)
    (,[^,]+|[.]distribute)? (,quiet)?
\z};

sub remove {
    my $self    = shift;
    my $handle  = shift;
    my %options = @_;

    return 1
        if $options{validated_by} and $handle->basename =~ /[.]distribute\z/;
    return $self->SUPER::remove($handle, %options);
}

sub html_remove {
    my $self    = shift;
    my $message = shift;

    Sympa::Tools::File::remove_dir(
        join('/',
            $self->{html_base_directory}, $message->{context}->get_id,
            $message->{authkey})
        )
        if $message
        and $message->{authkey}
        and ref $message->{context} eq 'Sympa::List';

    return;
}

sub size {
    scalar grep { !/(?:,\S+|[.]distribute)\z/ } @{shift->_load || []};
}

sub html_store {
    my $self    = shift;
    my $message = shift;
    my $modkey  = shift;

    if ($modkey and $modkey =~ /\A\w+\z/) {
        # Prepare HTML view of this message.
        # Note: 6.2a.32 or earlier stored HTML view into modqueue.
        # 6.2b has dedicated directory specified by viewmail_dir parameter.
        my $list_id  = $message->{context}->get_id;
        my $listname = $message->{context}->{'name'};
        Sympa::Archive::html_format(
            $message,
            destination_dir =>
                join('/', $self->{html_base_directory}, $list_id, $modkey),
            attachment_url => ['viewmod', $listname, $modkey]
        );
    }

    return;
}

1;
__END__

=encoding utf-8

=head1 NAME

Sympa::Spool::Moderation - Spool for held messages waiting for moderation

=head1 SYNOPSIS

  use Sympa::Spool::Moderation;

  my $spool = Sympa::Spool::Moderation->new;
  my $modkey = $spool->store($message);

  my $spool = Sympa::Spool::Moderation->new(
        context => $list, authkey => $modkey);
  my ($message, $handle) = $spool->next;

  $spool->remove($handle, validated_by => $validator, quiet => 1);
  $spool->remove($handle);

=head1 DESCRIPTION

L<Sympa::Spool::Moderation> implements the spool for held messages waiting
for moderation.

=head2 Methods

See L<Sympa::Spool::Held/"Methods"> and L<Sympa::Spool/"Public methods">
for methods derived from them.

=head2 Methods specific to this module

=over

=item html_remove ( $metadata )

I<Instance method>.
Removes cached HTML view of a message.

Parameters:

=over

=item $metadata

Hashref or message containing metadata.
At least C<context> and C<authkey> are required.

=back

Returns:

None.

=item html_store ( $message, $modkey )

I<Instance method>.
Caches HTML view of message.

Parameters:

=over

=item $message

Message to be stored.

=item $modkey

Moderation key.

=back

Returns:

None.

=back

=head2 Context and metadata

See L<Sympa::Spool:;:Held/"Context and metadata"> and
L<Sympa::Spool/"Marshaling and unmarshaling metadata">.

=head1 CONFIGURATION PARAMETERS

Following site configuration parameters in sympa.conf will be referred.

=over

=item queuemod

Directory path of moderation spool.

=item viewmail_dir

Root directory path of directories where HTML view of messages are cached.

=back

=head1 SEE ALSO

L<sympa_msg(8)>, L<wwsympa(8)>,
L<Sympa::Message>, L<Sympa::Spool>.

=head1 HISTORY

L<Sympa::Spool::Moderation> appeared on Sympa 6.2.8.

=cut
