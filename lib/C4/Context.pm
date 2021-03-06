package C4::Context;
# Copyright 2002 Katipo Communications
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# Koha; if not, write to the Free Software Foundation, Inc., 59 Temple Place,
# Suite 330, Boston, MA  02111-1307 USA

use strict;
use warnings;
use vars qw($VERSION $context @context_stack);

use Try::Tiny;
use CHI;
use DBI;
use Carp;
use XML::Simple;
use File::Slurp;
use C4::Boolean;
use C4::Debug;
use POSIX ();
use JSON qw(from_json);
use Koha;
require Koha::RoseDB;

$VERSION = '4.09.00.022';

=head1 NAME

C4::Context - Maintain and manipulate the context of a Koha script

=head1 SYNOPSIS

  use C4::Context;

  use C4::Context("/path/to/koha-conf.xml");

  $config_value = C4::Context->config("config_variable");

  $koha_preference = C4::Context->preference("preference");

  $db_handle = C4::Context->dbh;

  $stopwordhash = C4::Context->stopwords;

=head1 DESCRIPTION

When a Koha script runs, it makes use of a certain number of things:
configuration settings in F</etc/koha/koha-conf.xml>, a connection to the Koha
databases, and so forth. These things make up the I<context> in which
the script runs.

This module takes care of setting up the context for a script:
figuring out which configuration file to load, and loading it, opening
a connection to the right database, and so forth.

Most scripts will only use one context. They can simply have

  use C4::Context;

at the top.

Other scripts may need to use several contexts. For instance, if a
library has two databases, one for a certain collection, and the other
for everything else, it might be necessary for a script to use two
different contexts to search both databases. Such scripts should use
the C<&set_context> and C<&restore_context> functions, below.

By default, C4::Context reads the configuration from
F</etc/koha/koha-conf.xml>. This may be overridden by setting the C<$KOHA_CONF>
environment variable to the pathname of a configuration file to use.

=head1 METHODS

=over 2

=cut

#'
# In addition to what is said in the POD above, a Context object is a
# reference-to-hash with the following fields:
#
# config
#    A reference-to-hash whose keys and values are the
#    configuration variables and values specified in the config
#    file (/etc/koha/koha-conf.xml).
# dbconn
#    A Koha::RoseDB for the appropriate database for this context.

# Koha's main configuration file koha-conf.xml
# is searched for according to this priority list:
#
# 1. Path supplied via use C4::Context '/path/to/koha-conf.xml'
# 2. Path supplied in KOHA_CONF environment variable.
# 3. Path supplied in INSTALLED_CONFIG_FNAME, as long
#    as value has changed from its default of 
#    '__KOHA_CONF_DIR__/koha-conf.xml', as happens
#    when Koha is installed in 'standard' or 'single'
#    mode.
# 4. Path supplied in CONFIG_FNAME.
#
# The first entry that refers to a readable file is used.

use constant CONFIG_FNAME => "/etc/koha/koha-conf.xml";
                # Default config file, if none is specified
                
my $INSTALLED_CONFIG_FNAME = '__KOHA_CONF_DIR__/koha-conf.xml';
                # path to config file set by installer
                # __KOHA_CONF_DIR__ is set by rewrite-confg.PL
                # when Koha is installed in 'standard' or 'single'
                # mode.  If Koha was installed in 'dev' mode, 
                # __KOHA_CONF_DIR__ is *not* rewritten; instead
                # developers should set the KOHA_CONF environment variable 

$context = undef;        # Initially, no context is set
@context_stack = ();        # Initially, no saved contexts


=item KOHAVERSION
    returns the kohaversion

=cut

sub KOHAVERSION {
    return $C4::Context::VERSION;
}

=item read_config_file

=over 4

Reads the specified Koha config file. 

Returns an object containing the configuration variables. The object's
structure is a bit complex to the uninitiated ... take a look at the
koha-conf.xml file as well as the XML::Simple documentation for details. Or,
here are a few examples that may give you what you need:

The simple elements nested within the <config> element:

    my $pass = $koha->{'config'}->{'pass'};

The <listen> elements:

    my $listen = $koha->{'listen'}->{'biblioserver'}->{'content'};

The elements nested within the <server> element:

    my $ccl2rpn = $koha->{'server'}->{'biblioserver'}->{'cql2rpn'};

Returns undef in case of error.

=back

=cut

sub read_config_file {		# Pass argument naming config file to read
    my $koha = XMLin(shift, keyattr => ['id'], forcearray => ['listen', 'server', 'serverinfo'], suppressempty => '');
    return $koha;			# Return value: ref-to-hash holding the configuration
}

# db_scheme2dbi
# Translates the full text name of a database into de appropiate dbi name
# 
sub db_scheme2dbi {
    my $name = shift;

    for ($name) {
# FIXME - Should have other databases. 
        if (/mysql/i) { return("mysql"); }
        if (/Postgres|Pg|PostgresSQL/) { return("Pg"); }
        if (/oracle/i) { return("Oracle"); }
    }
    return undef;         # Just in case
}

sub import {
    # Create the default context ($C4::Context::Context)
    # the first time the module is called
    # (a config file can be optionaly passed)

    # default context allready exists? 
    return if $context;

    # no ? so load it!
    my ($pkg,$config_file) = @_ ;
    my $new_ctx = __PACKAGE__->new($config_file);
    return unless $new_ctx;

    # if successfully loaded, use it by default
    $new_ctx->set_context;
    1;
}

=item new

  $context = new C4::Context;
  $context = new C4::Context("/path/to/koha-conf.xml");

Allocates a new context. Initializes the context from the specified
file, which defaults to either the file given by the C<$KOHA_CONF>
environment variable, or F</etc/koha/koha-conf.xml>.

C<&new> does not set this context as the new default context; for
that, use C<&set_context>.

=cut

#'
# Revision History:
# 2004-08-10 A. Tarallo: Added check if the conf file is not empty
sub new {
    my $class = shift;
    my $conf_fname = shift;        # Config file to load
    my $self = {};

    # check that the specified config file exists and is not empty
    undef $conf_fname unless 
        (defined $conf_fname && -s $conf_fname);
    # Figure out a good config file to load if none was specified.
    if (!defined($conf_fname))
    {
        # If the $KOHA_CONF environment variable is set, use
        # that. Otherwise, use the built-in default.
        if (exists $ENV{"KOHA_CONF"} and $ENV{'KOHA_CONF'} and -s  $ENV{"KOHA_CONF"}) {
            $conf_fname = $ENV{"KOHA_CONF"};
        } elsif ($INSTALLED_CONFIG_FNAME !~ /__KOHA_CONF_DIR/ and -s $INSTALLED_CONFIG_FNAME) {
            # NOTE: be careful -- don't change __KOHA_CONF_DIR in the above
            # regex to anything else -- don't want installer to rewrite it
            $conf_fname = $INSTALLED_CONFIG_FNAME;
        } elsif (-s CONFIG_FNAME) {
            $conf_fname = CONFIG_FNAME;
        } else {
            croak "unable to locate Koha configuration file koha-conf.xml";
        }
    }
        # Load the desired config file.
    $self = read_config_file($conf_fname);
    $self->{"config_file"} = $conf_fname;
    
    warn "read_config_file($conf_fname) returned undef" if !defined($self->{"config"});
    return undef if !defined($self->{"config"});

    $ENV{TZ} = $self->{config}{timezone} || $ENV{TZ};
    $self->{dbconn} = undef;        # Database handle
    $self->{"stopwords"} = undef; # stopwords list
    $self->{"marcfromkohafield"} = undef; # the hash with relations between koha table fields and MARC field/subfield
    $self->{"userenv"} = undef;        # User env
    $self->{"activeuser"} = undef;        # current active user
    $self->{"shelves"} = undef;
    $self->{cachehash} = {};
    $self->{caches} = {};

    bless $self, $class;
    return $self;
}

sub DESTROY {
}

sub getcache {
    my ($self, $name, $args) = @_;
    $context->{caches}{$name} //= CHI->new(%{$args});
}

sub cachehash {
    return $context->{cachehash};
}

=item set_context

  $context = new C4::Context;
  $context->set_context();
or
  set_context C4::Context $context;

  ...
  restore_context C4::Context;

In some cases, it might be necessary for a script to use multiple
contexts. C<&set_context> saves the current context on a stack, then
sets the context to C<$context>, which will be used in future
operations. To restore the previous context, use C<&restore_context>.

=cut

#'
sub set_context
{
    my $self = shift;
    my $new_context;    # The context to set

    # Figure out whether this is a class or instance method call.
    #
    # We're going to make the assumption that control got here
    # through valid means, i.e., that the caller used an instance
    # or class method call, and that control got here through the
    # usual inheritance mechanisms. The caller can, of course,
    # break this assumption by playing silly buggers, but that's
    # harder to do than doing it properly, and harder to check
    # for.
    if (ref($self) eq "")
    {
        # Class method. The new context is the next argument.
        $new_context = shift;
    } else {
        # Instance method. The new context is $self.
        $new_context = $self;
    }

    # Save the old context, if any, on the stack
    push @context_stack, $context if defined($context);

    # Set the new context
    $context = $new_context;
}

=item restore_context

  &restore_context;

Restores the context set by C<&set_context>.

=cut

#'
sub restore_context
{
    my $self = shift;

    if ($#context_stack < 0)
    {
        # Stack underflow.
        die "Context stack underflow";
    }

    # Pop the old context and set it.
    $context = pop @context_stack;

    # FIXME - Should this return something, like maybe the context
    # that was current when this was called?
}

=item config

  $value = C4::Context->config("config_variable");

  $value = C4::Context->config_variable;

Returns the value of a variable specified in the configuration file
from which the current context was created.

The second form is more compact, but of course may conflict with
method names. If there is a configuration variable called "new", then
C<C4::Config-E<gt>new> will not return it.

=cut

sub _common_config ($$) {
	my $var = shift;
	my $term = shift;
    return undef if !defined($context->{$term});
       # Presumably $self->{$term} might be
       # undefined if the config file given to &new
       # didn't exist, and the caller didn't bother
       # to check the return value.

    # Return the value of the requested config variable
    return $context->{$term}->{$var};
}

sub opachosts {
	my $opachosts = _common_config($_[1], 'opachosts');
    return (ref($opachosts) eq 'ARRAY') ? $opachosts : [$opachosts];
}

sub config {
	return _common_config($_[1],'config');
}
sub zebraconfig {
	return _common_config($_[1],'server');
}

sub intranetdir { return $context->config('intranetdir') }

=item preference

  $sys_preference = C4::Context->preference('some_variable');

Looks up the value of the given system preference in the
systempreferences table of the Koha database, and returns it. If the
variable is not set or does not exist, it attempts to set it from the
default if a defaults file exists.

In case of an error, this may return undef.

Note: It is impossible to tell the difference between system
preferences which do not exist, and those whose values are set to NULL
with this method.

=cut

sub _seed_preference_defaults_cache {
    my $defaults_filename
        = C4::Context->config('basedir') . '/installer/data/syspref_defaults.json';

    my $json = File::Slurp::read_file($defaults_filename);

    return from_json($json);
}

sub preference_defaults {
    my $cache = C4::Context->getcache(__PACKAGE__,
                                      {driver => 'RawMemory',
                                      datastore => C4::Context->cachehash});
    return $cache->compute('systempreferences_defaults', '1h', \&_seed_preference_defaults_cache);
}

sub _seed_preferences_cache {
    my $matrix_ref
        = C4::Context->dbh->selectall_arrayref(
        'SELECT variable, value FROM systempreferences',
        {Slice => {}} );

    my %syspref_cache = map { $_->{variable} => $_->{value}} @$matrix_ref;
    return \%syspref_cache;
}

sub _clear_syspref_cache {
    shift; #unused
    my $cache = C4::Context->getcache(__PACKAGE__,
                                      {driver => 'RawMemory',
                                      datastore => C4::Context->cachehash});
    $cache->remove('systempreferences');
}

sub preference_set {
    my ($class, $var, $val) = @_;

    $class->_clear_syspref_cache();
    C4::Context->dbh->do(
        'INSERT INTO systempreferences (variable, value) VALUES (?,?) '.
        'ON DUPLICATE KEY UPDATE value=?',
        undef, $var, $val, $val);
}

sub preference {
    my $self = shift;
    my $var  = shift;

    my $cache = C4::Context->getcache(__PACKAGE__,
                                      {driver => 'RawMemory',
                                      datastore => C4::Context->cachehash});
    my $sysprefs = $cache->compute('systempreferences', '1m', \&_seed_preferences_cache);

    # Just return the variable's value if we have it
    return $sysprefs->{$var} if exists $sysprefs->{$var};

    # Otherwise, scan for the variable in the defaults file
    my $defaults = preference_defaults();
    croak 'Cannot find syspref defaults' unless $defaults;

    # Die if the variable isn't listed
    my $new_var = $defaults->{$var};
    croak "Systempreference '$var' is not registered" unless $new_var;

    # Otherwise write the variable to the DB
    $self->preference_set($var, $new_var->{value});

    return $new_var->{value};
}

sub boolean_preference ($) {
    my $self = shift;
    my $var = shift;        # The system preference to return
    my $it = preference($self, $var);
    my $val = try {
        return defined($it)? C4::Boolean::true_p($it): undef;
    }
    catch {
        carp "Non-boolean value for boolean syspref '$var'. Using default.";
        return preference_defaults()->{$var};
    };
    return $val;
}

=item dbh

  $dbh = C4::Context->dbh;

Returns a database handle connected to the Koha database for the
current context. If no connection has yet been made, this method
creates one, and connects to the database.

This database handle is cached for future use: if you call
C<C4::Context-E<gt>dbh> twice, you will get the same handle both
times.

=cut

sub _db_connect {
    my $type = shift;

    my $db = Koha::RoseDB->new( type => $type );

    $db->dbh->{mysql_enable_utf8} = 1;
    $db->dbh->do(q{set NAMES 'utf8'});
    $db->dbh->do(q{SET time_zone = ?}, undef, $ENV{TZ}) if $ENV{TZ};

    return $db;
}

sub dbconn {
    return $context->{dbconn} if $context->{dbconn};

    Koha::RoseDB->register_db(
        domain   => Koha::RoseDB->default_domain,
        type     => Koha::RoseDB->default_type,
        driver   => 'mysql',
        database => C4::Context->config('database'),
        host     => C4::Context->config('hostname'),
        port     => C4::Context->config('port'),
        username => C4::Context->config('user'),
        password => C4::Context->config('pass'),
        connect_options => {
            RaiseError => 1,
            AutoCommit => 1,
        },
    );

    return $context->{dbconn} = _db_connect('default');
}

sub replica_dbconn {
    return $context->{replica_dbconn} if $context->{replica_dbconn};
    return $context->{replica_dbconn} = dbconn()
        unless C4::Context->preference('Replica_DSN');

    Koha::RoseDB->register_db(
        domain   => Koha::RoseDB->default_domain,
        type     => 'report',
        driver   => 'mysql',
        dsn      => C4::Context->preference('Replica_DSN'),
        username => C4::Context->preference('Replica_user'),
        password => C4::Context->preference('Replica_pass'),
        connect_options => {
            RaiseError => 1,
            AutoCommit => 1,
        },
    );

    return $context->{replica_dbconn} = _db_connect('report');
}

sub db_check_mode {
    shift if $_[0] ~~ __PACKAGE__;
    $context->{db_check_mode} = shift if @_;
    return $context->{db_check_mode} ? 1 : 0;
}

sub _dbh_maybe_check {
    my $db = shift;

    no strict qw/refs/;
    delete $context->{$db}
        if (db_check_mode() && ! &{$db}()->dbh->ping);

    return &{$db}()->dbh;
}

sub dbh {
    return _dbh_maybe_check('dbconn');
}

sub replica_dbh {
    return _dbh_maybe_check('replica_dbconn');
}

=item marcfromkohafield

  $dbh = C4::Context->marcfromkohafield;

Returns a hash with marcfromkohafield.

This hash is cached for future use: if you call
C<C4::Context-E<gt>marcfromkohafield> twice, you will get the same hash without real DB access

=cut

#'
sub marcfromkohafield
{
    my $retval = {};

    # If the hash already exists, return it.
    return $context->{"marcfromkohafield"} if defined($context->{"marcfromkohafield"});

    # No hash. Create one.
    $context->{"marcfromkohafield"} = &_new_marcfromkohafield();

    return $context->{"marcfromkohafield"};
}

# _new_marcfromkohafield
# Internal helper function (not a method!). This creates a new
# hash with stopwords
sub _new_marcfromkohafield
{
    my $dbh = C4::Context->dbh;
    my $marcfromkohafield;
    my $sth = $dbh->prepare("select frameworkcode,kohafield,tagfield,tagsubfield from marc_subfield_structure where kohafield > ''");
    $sth->execute;
    while (my ($frameworkcode,$kohafield,$tagfield,$tagsubfield) = $sth->fetchrow) {
        my $retval = {};
        $marcfromkohafield->{$frameworkcode}->{$kohafield} = [$tagfield,$tagsubfield];
    }
    return $marcfromkohafield;
}

=item stopwords

  $dbh = C4::Context->stopwords;

Returns a hash with stopwords.

This hash is cached for future use: if you call
C<C4::Context-E<gt>stopwords> twice, you will get the same hash without real DB access

=cut

#'
sub stopwords
{
    my $retval = {};

    # If the hash already exists, return it.
    return $context->{"stopwords"} if defined($context->{"stopwords"});

    # No hash. Create one.
    $context->{"stopwords"} = &_new_stopwords();

    return $context->{"stopwords"};
}

# _new_stopwords
# Internal helper function (not a method!). This creates a new
# hash with stopwords
sub _new_stopwords
{
    my $dbh = C4::Context->dbh;
    my $stopwordlist;
    my $sth = $dbh->prepare("select word from stopwords");
    $sth->execute;
    while (my $stopword = $sth->fetchrow_array) {
        $stopwordlist->{$stopword} = uc($stopword);
    }
    $stopwordlist->{A} = "A" unless $stopwordlist;
    return $stopwordlist;
}

=item userenv

  C4::Context->userenv;

Retrieves a hash for user environment variables.

This hash shall be cached for future use: if you call
C<C4::Context-E<gt>userenv> twice, you will get the same hash without real DB access

=cut

#'
sub userenv {
    my $var = $context->{"activeuser"};
    return $context->{"userenv"}->{$var} if (defined $var and defined $context->{"userenv"}->{$var});
    # insecure=1 management
    if ($context->{"dbh"} && $context->preference('insecure')) {
        my %insecure;
        $insecure{flags} = '16382';
        $insecure{branchname} ='Insecure';
        $insecure{number} ='0';
        $insecure{cardnumber} ='0';
        $insecure{id} = 'insecure';
        $insecure{branch} = 'INS';
        $insecure{emailaddress} = 'test@mode.insecure.com';
        return \%insecure;
    } else {
        return;
    }
}

=item set_userenv

  C4::Context->set_userenv($usernum, $userid, $usercnum, $userfirstname, $usersurname, $userbranch, $userflags, $emailaddress);

Establish a hash of user environment variables.

set_userenv is called in Auth.pm

=cut

#'
sub set_userenv {
    my ($usernum, $userid, $usercnum, $userfirstname, $usersurname, $userbranch, $branchname, $userflags, $emailaddress, $branchprinter)= @_;
    my $var=$context->{"activeuser"};
    my $cell = {
        "number"     => $usernum,
        "id"         => $userid,
        "cardnumber" => $usercnum,
        "firstname"  => $userfirstname,
        "surname"    => $usersurname,
        #possibly a law problem
        "branch"     => $userbranch,
        "branchname" => $branchname,
        "flags"      => $userflags,
        "emailaddress"     => $emailaddress,
        "branchprinter"    => $branchprinter
    };
    $context->{userenv}->{$var} = $cell;
    return $cell;
}

sub set_shelves_userenv ($$) {
	my ($type, $shelves) = @_ or return undef;
	my $activeuser = $context->{activeuser} or return undef;
	$context->{userenv}->{$activeuser}->{barshelves} = $shelves if $type eq 'bar';
	$context->{userenv}->{$activeuser}->{pubshelves} = $shelves if $type eq 'pub';
	$context->{userenv}->{$activeuser}->{totshelves} = $shelves if $type eq 'tot';
}

sub get_shelves_userenv () {
	my $active;
	unless ($active = $context->{userenv}->{$context->{activeuser}}) {
		$debug and warn "get_shelves_userenv cannot retrieve context->{userenv}->{context->{activeuser}}";
		return undef;
	}
	my $totshelves = $active->{totshelves} or undef;
	my $pubshelves = $active->{pubshelves} or undef;
	my $barshelves = $active->{barshelves} or undef;
	return ($totshelves, $pubshelves, $barshelves);
}

=item _new_userenv

  C4::Context->_new_userenv($session);  # FIXME: This calling style is wrong for what looks like an _internal function

Builds a hash for user environment variables.

This hash shall be cached for future use: if you call
C<C4::Context-E<gt>userenv> twice, you will get the same hash without real DB access

_new_userenv is called in Auth.pm

=cut

#'
sub _new_userenv
{
    shift;  # Useless except it compensates for bad calling style
    my ($sessionID)= @_;
     $context->{"activeuser"}=$sessionID;
}

=item _unset_userenv

  C4::Context->_unset_userenv;

Destroys the hash for activeuser user environment variables.

=cut

#'

sub _unset_userenv
{
    my ($sessionID)= @_;
    undef $context->{"activeuser"} if ($context->{"activeuser"} eq $sessionID);
}


=item get_versions

  C4::Context->get_versions

Gets various version info, for core Koha packages, Currently called from carp handle_errors() sub, to send to browser if 'DebugLevel' syspref is set to '2'.

=cut

#'

# A little example sub to show more debugging info for CGI::Carp
sub get_versions {
    my %versions;
    $versions{kohaVersion}  = KOHAVERSION();
    $versions{kohaDbVersion} = C4::Context->preference('version');
    $versions{osVersion} = join(" ", POSIX::uname());
    $versions{perlVersion} = $];
    {
        no warnings qw(exec); # suppress warnings if unable to find a program in $PATH
        $versions{mysqlVersion}  = `mysql -V`;
        $versions{apacheVersion} = `httpd -v`;
        $versions{apacheVersion} = `httpd2 -v`            unless  $versions{apacheVersion} ;
        $versions{apacheVersion} = `apache2 -v`           unless  $versions{apacheVersion} ;
        $versions{apacheVersion} = `/usr/sbin/apache2 -v` unless  $versions{apacheVersion} ;
    }
    return %versions;
}


1;
__END__

=back

=head1 ENVIRONMENT

=over 4

=item C<KOHA_CONF>

Specifies the configuration file to read.

=back

=head1 SEE ALSO

XML::Simple

=head1 AUTHORS

Andrew Arensburger <arensb at ooblick dot com>

Joshua Ferraro <jmf at liblime dot com>

=cut

# Revision 1.57  2007/05/22 09:13:55  tipaul
# Bugfixes & improvements (various and minor) :
# - updating templates to have tmpl_process3.pl running without any errors
# - adding a drupal-like css for prog templates (with 3 small images)
# - fixing some bugs in circulation & other scripts
# - updating french translation
# - fixing some typos in templates
#
# Revision 1.56  2007/04/23 15:21:17  tipaul
# renaming currenttransfers to transferstoreceive
#
# Revision 1.55  2007/04/17 08:48:00  tipaul
# circulation cleaning continued: bufixing
#
# Revision 1.54  2007/03/29 16:45:53  tipaul
# Code cleaning of Biblio.pm (continued)
#
# All subs have be cleaned :
# - removed useless
# - merged some
# - reordering Biblio.pm completly
# - using only naming conventions
#
# Seems to have broken nothing, but it still has to be heavily tested.
# Note that Biblio.pm is now much more efficient than previously & probably more reliable as well.
#
# Revision 1.53  2007/03/29 13:30:31  tipaul
# Code cleaning :
# == Biblio.pm cleaning (useless) ==
# * some sub declaration dropped
# * removed modbiblio sub
# * removed moditem sub
# * removed newitems. It was used only in finishrecieve. Replaced by a TransformKohaToMarc+AddItem, that is better.
# * removed MARCkoha2marcItem
# * removed MARCdelsubfield declaration
# * removed MARCkoha2marcBiblio
#
# == Biblio.pm cleaning (naming conventions) ==
# * MARCgettagslib renamed to GetMarcStructure
# * MARCgetitems renamed to GetMarcItem
# * MARCfind_frameworkcode renamed to GetFrameworkCode
# * MARCmarc2koha renamed to TransformMarcToKoha
# * MARChtml2marc renamed to TransformHtmlToMarc
# * MARChtml2xml renamed to TranformeHtmlToXml
# * zebraop renamed to ModZebra
#
# == MARC=OFF ==
# * removing MARC=OFF related scripts (in cataloguing directory)
# * removed checkitems (function related to MARC=off feature, that is completly broken in head. If someone want to reintroduce it, hard work coming...)
# * removed getitemsbybiblioitem (used only by MARC=OFF scripts, that is removed as well)
#
# Revision 1.52  2007/03/16 01:25:08  kados
# Using my precrash CVS copy I did the following:
#
# cvs -z3 -d:ext:kados@cvs.savannah.nongnu.org:/sources/koha co -P koha
# find koha.precrash -type d -name "CVS" -exec rm -v {} \;
# cp -r koha.precrash/* koha/
# cd koha/
# cvs commit
#
# This should in theory put us right back where we were before the crash
#
# Revision 1.52  2007/03/12 21:17:05  rych
# add server, serverinfo as arrays from config
#
# Revision 1.51  2007/03/09 14:31:47  tipaul
# rel_3_0 moved to HEAD
#
# Revision 1.43.2.10  2007/02/09 17:17:56  hdl
# Managing a little better database absence.
# (preventing from BIG 550)
#
# Revision 1.43.2.9  2006/12/20 16:50:48  tipaul
# improving "insecure" management
#
# WARNING KADOS :
# you told me that you had some libraries with insecure=ON (behind a firewall).
# In this commit, I created a "fake" user when insecure=ON. It has a fake branch. You may find better to have the 1st branch in branch table instead of a fake one.
#
# Revision 1.43.2.8  2006/12/19 16:48:16  alaurin
# reident programs, and adding branchcode value in reserves
#
# Revision 1.43.2.7  2006/12/06 21:55:38  hdl
# Adding ModZebrations for servers to get serverinfos in Context.pm
# Using this function in rebuild_zebra.pl
#
# Revision 1.43.2.6  2006/11/24 21:18:31  kados
# very minor changes, no functional ones, just comments, etc.
#
# Revision 1.43.2.5  2006/10/30 13:24:16  toins
# fix some minor POD error.
#
# Revision 1.43.2.4  2006/10/12 21:42:49  hdl
# Managing multiple zebra connections
#
# Revision 1.43.2.3  2006/10/11 14:27:26  tipaul
# removing a warning
#
# Revision 1.43.2.2  2006/10/10 15:28:16  hdl
# BUG FIXING : using database name in Zconn if defined and not hard coded value
#
# Revision 1.43.2.1  2006/10/06 13:47:28  toins
# Synch with dev_week.
#  /!\ WARNING :: Please now use the new version of koha.xml.
#
# Revision 1.18.2.5.2.14  2006/09/24 15:24:06  kados
# remove Zebraauth routine, fold the functionality into Zconn
# Zconn can now take several arguments ... this will probably
# change soon as I'm not completely happy with the readability
# of the current format ... see the POD for details.
#
# cleaning up Biblio.pm, removing unnecessary routines.
#
# DeleteBiblio - used to delete a biblio from zebra and koha tables
#     -- checks to make sure there are no existing issues
#     -- saves backups of biblio,biblioitems,items in deleted* tables
#     -- does commit operation
#
# getRecord - used to retrieve one record from zebra in piggyback mode using biblionumber
# brought back z3950_extended_services routine
#
# Lots of modifications to Context.pm, you can now store user and pass info for
# multiple servers (for federated searching) using the <serverinfo> element.
# I'll commit my koha.xml to demonstrate this or you can refer to the POD in
# Context.pm (which I also expanded on).
#
# Revision 1.18.2.5.2.13  2006/08/10 02:10:21  kados
# Turned warnings on, and running a search turned up lots of warnings.
# Cleaned up those ...
#
# removed getitemtypes from Koha.pm (one in Search.pm looks newer)
# removed itemcount from Biblio.pm
#
# made some local subs local with a _ prefix (as they were redefined
# elsewhere)
#
# Add two new search subs to Search.pm the start of a new search API
# that's a bit more scalable
#
# Revision 1.18.2.5.2.10  2006/07/21 17:50:51  kados
# moving the *.properties files to intranetdir/etc dir
#
# Revision 1.18.2.5.2.9  2006/07/17 08:05:20  tipaul
# there was a hardcoded link to /koha/etc/ I replaced it with intranetdir config value
#
# Revision 1.18.2.5.2.8  2006/07/11 12:20:37  kados
# adding ccl and cql files ... Tumer, if you want to fit these into the
# config file by all means do.
#
# Revision 1.18.2.5.2.7  2006/06/04 22:50:33  tgarip1957
# We do not hard code cql2rpn conversion file in context.pm our koha.xml configuration file already describes the path for this file.
# At cql searching we use method CQL not CQL2RPN as the cql2rpn conversion file is defined at server level
#
# Revision 1.18.2.5.2.6  2006/06/02 23:11:24  kados
# Committing my working dev_week. It's been tested only with
# searching, and there's quite a lot of config stuff to set up
# beforehand. As things get closer to a release, we'll be making
# some scripts to do it for us
#
# Revision 1.18.2.5.2.5  2006/05/28 18:49:12  tgarip1957
# This is an unusual commit. The main purpose is a working model of Zebra on a modified rel2_2.
# Any questions regarding these commits should be asked to Joshua Ferraro unless you are Joshua whom I'll report to
#
# Revision 1.36  2006/05/09 13:28:08  tipaul
# adding the branchname and the librarian name in every page :
# - modified userenv to add branchname
# - modifier menus.inc to have the librarian name & userenv displayed on every page. they are in a librarian_information div.
#
# Revision 1.35  2006/04/13 08:40:11  plg
# bug fixed: typo on Zconnauth name
#
# Revision 1.34  2006/04/10 21:40:23  tgarip1957
# A new handler defined for zebra Zconnauth with read/write permission. Zconnauth should only be called in biblio.pm where write operations are. Use of this handler will break things unless koha.conf contains new variables:
# zebradb=localhost
# zebraport=<your port>
# zebrauser=<username>
# zebrapass=<password>
#
# The zebra.cfg file should read:
# perm.anonymous:r
# perm.username:rw
# passw.c:<yourpasswordfile>
#
# Password file should be prepared with Apaches htpasswd utility in encrypted mode and should exist in a folder zebra.cfg can read
#
# Revision 1.33  2006/03/15 11:21:56  plg
# bug fixed: utf-8 data where not displayed correctly in screens. Supposing
# your data are truely utf-8 encoded in your database, they should be
# correctly displayed. "set names 'UTF8'" on mysql connection (C4/Context.pm)
# is mandatory and "binmode" to utf8 (C4/Interface/CGI/Output.pm) seemed to
# converted data twice, so it was removed.
#
# Revision 1.32  2006/03/03 17:25:01  hdl
# Bug fixing : a line missed a comment sign.
#
# Revision 1.31  2006/03/03 16:45:36  kados
# Remove the search that tests the Zconn -- warning, still no fault
# tollerance
#
# Revision 1.30  2006/02/22 00:56:59  kados
# First go at a connection object for Zebra. You can now get a
# connection object by doing:
#
# my $Zconn = C4::Context->Zconn;
#
# My initial tests indicate that as soon as your funcion ends
# (ie, when you're done doing something) the connection will be
# closed automatically. There may be some other way to make the
# connection more stateful, I'm not sure...
#
# Local Variables:
# tab-width: 4
# End:
