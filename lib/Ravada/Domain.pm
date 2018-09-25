package Ravada::Domain;

use warnings;
use strict;

=head1 NAME

Ravada::Domain - Domains ( Virtual Machines ) library for Ravada

=cut

use Carp qw(carp confess croak cluck);
use Data::Dumper;
use File::Copy;
use File::Rsync;
use Hash::Util qw(lock_hash);
use Image::Magick;
use JSON::XS;
use Moose::Role;
use IPC::Run3 qw(run3);
use Time::Piece;

no warnings "experimental::signatures";
use feature qw(signatures);

use Ravada::Domain::Driver;
use Ravada::Utils;

our $TIMEOUT_SHUTDOWN = 20;
our $CONNECTOR;

our $MIN_FREE_MEMORY = 1024*1024;
our $IPTABLES_CHAIN = 'RAVADA';

our %PROPAGATE_FIELD = map { $_ => 1} qw( run_timeout );

our $TIME_CACHE_NETSTAT = 10; # seconds to cache netstat data output

_init_connector();

requires 'name';
requires 'remove';
requires 'display';

requires 'is_active';
requires 'is_hibernated';
requires 'is_paused';
requires 'is_removed';

requires 'start';
requires 'shutdown';
requires 'shutdown_now';
requires 'force_shutdown';
requires '_do_force_shutdown';

requires 'pause';
requires 'resume';
requires 'prepare_base';

requires 'rename';

#storage
requires 'add_volume';
requires 'list_volumes';

requires 'disk_device';

requires 'disk_size';

requires 'spinoff_volumes';

requires 'clean_swap_volumes';
#hardware info

requires 'get_info';
requires 'set_memory';
requires 'set_max_mem';

requires 'autostart';
requires 'hybernate';
requires 'hibernate';

#remote methods
requires 'migrate';

requires 'get_driver';
requires 'get_controller_by_name';
requires 'list_controllers';
requires 'set_controller';
requires 'remove_controller';
#
##########################################################

has 'domain' => (
    isa => 'Any'
    ,is => 'rw'
);

has 'timeout_shutdown' => (
    isa => 'Int'
    ,is => 'ro'
    ,default => $TIMEOUT_SHUTDOWN
);

has 'readonly' => (
    isa => 'Int'
    ,is => 'ro'
    ,default => 0
);

has 'storage' => (
    is => 'ro'
    ,isa => 'Object'
    ,required => 0
);

has '_vm' => (
    is => 'rw',
    ,isa => 'Object'
    ,required => 0
);

has 'tls' => (
    is => 'rw'
    ,isa => 'Int'
    ,default => 0
);

has 'description' => (
    is => 'rw'
    ,isa => 'Str'
    ,required => 0
    ,trigger => \&_update_description
);

##################################################################################3
#


##################################################################################3
#
# Method Modifiers
#

around 'display' => \&_around_display;

around 'add_volume' => \&_around_add_volume;

before 'remove' => \&_pre_remove_domain;
#\&_allow_remove;
 after 'remove' => \&_after_remove_domain;

before 'prepare_base' => \&_pre_prepare_base;
 after 'prepare_base' => \&_post_prepare_base;

before 'start' => \&_start_preconditions;
 after 'start' => \&_post_start;

before 'pause' => \&_allow_shutdown;
 after 'pause' => \&_post_pause;

before 'hybernate' => \&_allow_shutdown;
 after 'hybernate' => \&_post_hibernate;

before 'hibernate' => \&_allow_shutdown;
 after 'hibernate' => \&_post_hibernate;

before 'resume' => \&_allow_manage;
 after 'resume' => \&_post_resume;

before 'shutdown' => \&_pre_shutdown;
after 'shutdown' => \&_post_shutdown;

around 'shutdown_now' => \&_around_shutdown_now;
around 'force_shutdown' => \&_around_shutdown_now;

before 'remove_base' => \&_pre_remove_base;
after 'remove_base' => \&_post_remove_base;

before 'rename' => \&_pre_rename;
after 'rename' => \&_post_rename;

before 'clone' => \&_pre_clone;

after 'screenshot' => \&_post_screenshot;

after '_select_domain_db' => \&_post_select_domain_db;

before 'migrate' => \&_pre_migrate;
after 'migrate' => \&_post_migrate;

around 'get_info' => \&_around_get_info;
around 'set_max_mem' => \&_around_set_mem;
around 'set_memory' => \&_around_set_mem;

around 'is_active' => \&_around_is_active;

around 'is_active' => \&_around_is_active;

around 'autostart' => \&_around_autostart;

after 'set_controller' => \&_post_change_controller;
after 'remove_controller' => \&_post_change_controller;

around 'name' => \&_around_name;

##################################################
#

sub BUILD {
    my $self = shift;
    my $args = shift;

    my $name;
    $name = $args->{name}               if exists $args->{name};
    $name = $args->{domain}->get_name   if !$name && $args->{domain};

    $self->{_name} = $name  if $name;

    $self->_init_connector();

    $self->is_known();
}

sub _check_clean_shutdown($self) {
    if ( $self->is_known
        && !$self->readonly
        && $self->_data('status') eq 'active'
        && !$self->is_active ) {
            $self->_post_shutdown();
    }
}

sub _set_last_vm($self,$force=0) {
    my $id_vm;
    $id_vm = $self->_data('id_vm')  if $self->is_known();
    return $self->_set_vm($id_vm, $force)   if $id_vm;
}

sub _set_vm($self, $vm, $force=0) {
    if (!ref($vm)) {
        $vm = Ravada::VM->open($vm);
    }

    my $domain;
    eval { $domain = $vm->search_domain($self->name) };
    die $@ if $@ && $@ !~ /no domain with matching name/;
    if ($domain && ($force || $domain->is_active)) {
       $self->_vm($vm);
       $self->domain($domain->domain);
        $self->_update_id_vm();
    }
    return $vm->id;

}

sub _check_equal_storage_pools($self, $vm) {
     confess "ERROR: ".$vm->name." and ".$self->_vm->name
        ." have different storage pools "
        .Dumper([$vm->list_storage_pools],[$self->_vm->list_storage_pools])
            if !_equal_storage_pools($vm, $self->_vm);
}

sub _equal_storage_pools($vm1, $vm2) {
    my @sp1 = sort $vm1->list_storage_pools();
    my @sp2 = sort $vm2->list_storage_pools();
    return 0 if scalar @sp1 != scalar @sp2;

    for ( 0 .. $#sp1 ) {
        return 0 if $sp1[$_] ne $sp2[$_];
    }
    return 1;
}

sub _vm_connect {
    my $self = shift;
    $self->_vm->connect();
}

sub _vm_disconnect {
    my $self = shift;
    $self->_vm->disconnect();
}

sub _start_preconditions{
    my ($self) = @_;

    die "Domain ".$self->name." is a base. Bases can't get started.\n"
        if $self->is_base();

    my $request;
    if (scalar @_ %2 ) {
        my @args = @_;
        shift @args;
        my %args = @args;
        my $user = delete $args{user};
        my $remote_ip = delete $args{remote_ip};
        $request = $args{request} if exists $args{request};
        confess "ERROR: Unknown argument ".join("," , sort keys %args)
            ."\n\tknown: remote_ip, user"   if keys %args;
        _allow_manage_args(@_);
    } else {
        _allow_manage(@_);
    }
    #_check_used_memory(@_);

    return if $self->_search_already_started();
    # if it is a clone ( it is not a base )
    if ($self->id_base) {
#        $self->_set_last_vm(1)
        if ( !$self->is_local && !$self->_vm->ping ) {
            my $vm_local = $self->_vm->new( host => 'localhost' );
            $self->_set_vm($vm_local, 1);
        }
        $self->_balance_vm();
        $self->rsync()  if !$self->_vm->is_local();
    }
    $self->_check_free_vm_memory();
    #TODO: remove them and make it more general now we have nodes
    #$self->_check_cpu_usage($request);
}

sub _search_already_started($self) {
    my $sth = $$CONNECTOR->dbh->prepare(
        "SELECT id FROM vms where vm_type=?"
    );
    $sth->execute($self->_vm->type);
    my %started;
    while (my ($id) = $sth->fetchrow) {
        my $vm = Ravada::VM->open($id);
        next if !$vm->is_active;

        my $domain = $vm->search_domain($self->name);
        next if !$domain;
        if ( $domain->is_active || $domain->is_hibernated ) {
            $self->_set_vm($vm,'force');
            $started{$vm->id}++;

            my $status = 'shutdown';
            $status = 'active'  if $domain->is_active;
            $domain->_data(status => $status);
        }
    }
    if (keys %started > 1) {
        for my $id_vm (sort keys %started) {
            Ravada::Request->shutdown_domain(
                id_domain => $self->id
                , uid => $self->id_owner
                , id_vm => $id_vm
            );
        }
    }
    return keys %started;
}

sub _balance_vm($self) {
    return if $self->{_migrated};
    return if !$self->id_base;

    my $sth = $$CONNECTOR->dbh->prepare(
        "SELECT id FROM vms where vm_type=?"
    );
    $sth->execute($self->_vm->type);
    my %vm_list;
    for my $vm ($self->_vm->list_nodes) {
        next if !$vm->is_active();
        next if !$vm->is_active || $vm->free_memory < $MIN_FREE_MEMORY;
        $vm_list{$vm->id} = scalar($vm->list_domains(active => 1)).".".$vm->free_memory;
    }
    my @sorted_vm = sort { $vm_list{$a} <=> $vm_list{$b} } keys %vm_list;

    my $base = Ravada::Domain->open($self->id_base);
    for my $id (@sorted_vm) {
        if ( $base->base_in_vm($id) ) {
            return if $id == $self->_vm->id;

            my $vm_free = Ravada::VM->open($id);

            $self->migrate($vm_free);
            return $id;
        }
    }
    return;
}

sub _update_description {
    my $self = shift;

    return if defined $self->description
        && defined $self->_data('description')
        && $self->description eq $self->_data('description');

    my $sth = $$CONNECTOR->dbh->prepare(
        "UPDATE domains SET description=? "
        ." WHERE id=? ");
    $sth->execute($self->description,$self->id);
    $sth->finish;
    $self->{_data}->{description} = $self->{description};
}

sub _allow_manage_args {
    my $self = shift;

    confess "Disabled from read only connection"
        if $self->readonly;

    my %args = @_;

    confess "Missing user arg ".Dumper(\%args)
        if !$args{user} ;

    $self->_allowed($args{user});

}
sub _allow_manage {
    my $self = shift;

    return $self->_allow_manage_args(@_)
        if scalar(@_) % 2 == 0;

    my ($user) = @_;
    return $self->_allow_manage_args( user => $user);

}

sub _allow_remove($self, $user) {

    confess "ERROR: Undefined user" if !defined $user;

    die "ERROR: remove not allowed for user ".$user->name
        unless $user->can_remove_machine($self);

    $self->_check_has_clones() if $self->is_known();
    if ( $self->is_known
        && $self->id_base
        && ($user->can_remove_clones() || $user->can_remove_clone_all())
    ) {
        my $base = $self->open($self->id_base);
        return if ($user->can_remove_clone_all() || ($base->id_owner == $user->id));
    }

}

sub _allow_shutdown {
    my $self = shift;
    my %args;

    if (scalar @_ == 1 ) {
        $args{user} = shift;
    } else {
        %args = @_;
    }
    my $user = $args{user} || confess "ERROR: Missing user arg";

    if ( $self->id_base() && $user->can_shutdown_clone()) {
        my $base = Ravada::Domain->open($self->id_base)
            or confess "ERROR: Base domain id: ".$self->id_base." not found";
        return if $base->id_owner == $user->id;
    } elsif($user->can_shutdown_all) {
        return;
    }
    confess "User ".$user->name." [".$user->id."] not allowed to shutdown ".$self->name
        ." owned by ".($self->id_owner or '<UNDEF>')
            if !$user->can_shutdown($self->id);
}

sub _around_add_volume {
    my $orig = shift;
    my $self = shift;
    confess "ERROR in args ".Dumper(\@_)
        if scalar @_ % 2;
    my %args = @_;

    my $path = $args{path};
    if ( $path ) {
        my $name = $args{name};
        if (!$name) {
            ($args{name}) = $path =~ m{.*/(.*)};
        }
    }
    return $self->$orig(%args);
}

sub _pre_prepare_base($self, $user, $request = undef ) {

    $self->_allowed($user);

    my $owner = Ravada::Auth::SQL->search_by_id($self->id_owner);
    confess "User ".$user->name." [".$user->id."] not allowed to prepare base ".$self->domain
        ." owned by ".($owner->name or '<UNDEF>')."\n"
            unless $user->is_admin || (
                $self->id_owner == $user->id && $user->can_create_base());


    # TODO: if disk is not base and disks have not been modified, do not generate them
    # again, just re-attach them 
#    $self->_check_disk_modified(
    confess "ERROR: domain ".$self->name." is already a base" if $self->is_base();
    $self->_check_has_clones();

    $self->is_base(0);
    $self->_post_remove_base();
    if ($self->is_active) {
        $self->shutdown(user => $user);
        for ( 1 .. $TIMEOUT_SHUTDOWN ) {
            last if !$self->is_active;
            sleep 1;
        }
        if ($self->is_active ) {
            $request->status('working'
                    ,"Domain ".$self->name." still active, forcing hard shutdown")
                if $request;
            $self->force_shutdown($user);
            sleep 1;
        }
    }
    if ($self->id_base ) {
        $self->spinoff_volumes();
    }
};

sub _post_prepare_base {
    my $self = shift;

    my ($user) = @_;

    $self->is_base(1);

    if ($self->id_base && !$self->description()) {
        my $base = Ravada::Domain->open($self->id_base);
        $self->description($base->description)  if $base->description();
    }

    $self->_remove_id_base();
    $self->_set_base_vm_db($self->_vm->id,1);
    $self->autostart(0,$user);
};

sub _around_autostart($orig, $self, @arg) {
    my ($value, $user) = @arg;
    $self->_allowed($user) if defined $value;
    confess "ERROR: Autostart can't be activated on base ".$self->name
        if $value && $self->is_base;

    confess "ERROR: You can't set autostart on readonly domains"
        if defined $value && $self->readonly;
    my $autostart = 0;
    my @orig_args = ();
    push @orig_args, ( $value) if defined $value;
    if ( $self->$orig(@orig_args) ) {
        $autostart = 1;
    }
    $self->_data(autostart => $autostart)   if defined $value;
    return $autostart;
}

sub _check_has_clones {
    my $self = shift;
    return if !$self->is_known();

    my @clones = $self->clones;
    die "Domain ".$self->name." has ".scalar @clones." clones : ".Dumper(\@clones)
        if $#clones>=0;
}

sub _check_free_vm_memory {
    my $self = shift;

    return if !$self->_vm->min_free_memory;
    my $vm_free_mem = $self->_vm->free_memory;

    return if $vm_free_mem > $self->_vm->min_free_memory;

    my $msg = "Error: No free memory. Only "._gb($vm_free_mem)." out of "
        ._gb($self->_vm->min_free_memory)." GB required.\n";

    die $msg;
}

sub _check_cpu_usage($self, $request=undef){

    return if ref($self) =~ /Void/i;
    if ($self->_vm->active_limit){
        chomp(my $cpu_count = `grep -c -P '^processor\\s+:' /proc/cpuinfo`);
        die "Error: Too many active domains." if (scalar $self->_vm->vm->list_domains() >= $self->_vm->active_limit);
    }
    
    my @cpu;
    my $msg;
    for ( 1 .. 10 ) {
        open( my $stat ,'<','/proc/loadavg') or die "WTF: $!";
        @cpu = split /\s+/, <$stat>;
        close $stat;

        if ( $cpu[0] < $self->_vm->max_load ) {
            $request->error('') if $request;
            return;
        }
        $msg = "Error: CPU Too loaded. ".($cpu[0])." out of "
        	.$self->_vm->max_load." max specified.";
        $request->error($msg)   if $request;
        die "$msg\n" if $cpu[0] > $self->_vm->max_load +1;
        sleep 1;
    }
    die "$msg\n";
}

sub _gb($mem=0) {
    my $gb = $mem / 1024 / 1024 ;

    $gb =~ s/(\d+\.\d).*/$1/;
    return ($gb);

}

=pod

sub _check_disk_modified {
    my $self = shift;

    if ( !$self->is_base() ) {
        return;
    }

    my $last_stat_base = 0;
    for my $file_base ( $self->list_files_base ) {
        my @stat_base = stat($file_base);
        $last_stat_base = $stat_base[9] if$stat_base[9] > $last_stat_base;
#        warn $last_stat_base;
    }

    my $files_updated = 0;
    for my $file ( $self->disk_device ) {
        my @stat = stat($file) or next;
        $files_updated++ if $stat[9] > $last_stat_base;
#        warn "\ncheck\t$file ".$stat[9]."\n vs \tfile_base $last_stat_base $files_updated\n";
    }
    die "Base already created and no disk images updated"
        if !$files_updated;
}

=cut

sub _allowed {
    my $self = shift;

    my ($user) = @_;

    confess "Missing user"  if !defined $user;
    confess "ERROR: User '$user' not class user , it is ".(ref($user) or 'SCALAR')
        if !ref $user || ref($user) !~ /Ravada::Auth/;

    return if $user->is_admin;
    my $id_owner;
    eval { $id_owner = $self->id_owner };
    my $err = $@;

    confess "User ".$user->name." [".$user->id."] not allowed to access ".$self->name
        ." owned by ".($id_owner or '<UNDEF>')
            if (defined $id_owner && $id_owner != $user->id );

    confess $err if $err;

}

sub _around_display($orig,$self,$user) {
    $self->_allowed($user);
    my $display = $self->$orig($user);
    $self->_data(display => $display)   if !$self->readonly;
    return $display;
}

sub _around_get_info($orig, $self) {
    my $info = $self->$orig();
    if (ref($self) =~ /^Ravada::Domain/ && $self->is_known()) {
        $self->_data(info => encode_json($info));
    }
    return $info;
}

sub _around_set_mem($orig, $self, $value) {
    my $ret = $self->$orig($value);
    if ($self->is_known) {
        my $info;
        eval { $info = decode_json($self->_data('info')) if $self->_data('info')};
        warn $@ if $@ && $@ !~ /malformed JSON/i;
        $info->{memory} = $value;
        $self->_data(info => encode_json($info))
    }
    return $ret;
}

##################################################################################3

sub _init_connector {
    return if $CONNECTOR && $$CONNECTOR;
    $CONNECTOR = \$Ravada::CONNECTOR if $Ravada::CONNECTOR;
    $CONNECTOR = \$Ravada::Front::CONNECTOR if !defined $$CONNECTOR
                                                && defined $Ravada::Front::CONNECTOR;
}

=head2 id
Returns the id of  the domain
    my $id = $domain->id();
=cut

sub id($self) {
    return $self->{_id} if exists $self->{_id};
    my $id = $_[0]->_data('id');
    $self->{_id} = $id;
    return $id;
}


##################################################################################

sub _data($self, $field, $value=undef, $table='domains') {

    _init_connector();

    my $data = "_data";
    my $field_id = 'id';
    if ($table ne 'domains' ) {
        $data = "_data_$table";
        $field_id = 'id_domain';
    }

    if (defined $value) {
        confess "Domain ".$self->name." is not in the DB"
            if !$self->is_known();

        confess "ERROR: Invalid field '$field'"
            if $field !~ /^[a-z]+[a-z0-9_]*$/;

        my $sth = $$CONNECTOR->dbh->prepare(
            "UPDATE $table set $field=? WHERE $field_id=?"
        );
        $sth->execute($value, $self->id);
        $sth->finish;
        $self->{$data}->{$field} = $value;
        $self->_propagate_data($field,$value) if $PROPAGATE_FIELD{$field};
    }
    return $self->{$data}->{$field} if exists $self->{$data}->{$field};

    my @field_select;
    if ($table eq 'domains' ) {
        if (exists $self->{_data}->{id} ) {
            @field_select = ( id => $self->{_data}->{id});
        } else {
            confess "ERROR: Unknown domain" if ref($self) =~ /^Ravada::Front::Domain/;
            @field_select = ( name => $self->name );
        }
    } else {
        @field_select = ( id_domain => $self->id );
    }

    $self->{$data} = $self->_select_domain_db( _table => $table, @field_select );

    confess "No DB info for domain @field_select in $table ".$self->name 
        if ! exists $self->{$data};
    confess "No field $field in $data ".Dumper(\@field_select)."\n".Dumper($self->{$data})
        if !exists $self->{$data}->{$field};

    return $self->{$data}->{$field};
}

sub _data_extra($self, $field, $value=undef) {
    $self->_insert_db_extra()   if !$self->is_known_extra();
    return $self->_data($field, $value, "domains_".lc($self->type));
}

=head2 open

Open a domain

Argument: id
Arguments: id => $id , [ readonly => {0|1} ]

Returns: Domain object

=cut

sub open($class, @args) {
    my ($id) = @args;
    my $readonly = 0;
    my $id_vm;
    my $force;

    if (scalar @args > 1) {
        my %args = @args;
        $id = delete $args{id} or confess "ERROR: Missing field id";
        $readonly = delete $args{readonly} if exists $args{readonly};
        $id_vm = delete $args{id_vm};
        $force = delete $args{_force};
        confess "ERROR: Unknown fields ".join(",", sort keys %args)
            if keys %args;
    }
    confess "Undefined id"  if !defined $id;
    my $self = {};

    if (ref($class)) {
        $self = $class;
    } else {
        bless $self,$class
    }

    my $row = $self->_select_domain_db ( id => $id );

    die "ERROR: Domain not found id=$id\n"
        if !keys %$row;

    my $vm;
    my $vm_local = {};
    my $vm_class = "Ravada::VM::".$row->{vm};
    bless $vm_local, $vm_class;

    if ($id_vm || ( $self->_data('id_vm') && !$self->is_base) ) {
        $vm = Ravada::VM->open(id => ( $id_vm or $self->_data('id_vm') )
                , readonly => $readonly);
    }
    if (!$vm || !$vm->is_active) {
        $vm = $vm_local->new( );
    }

    my $domain = $vm->search_domain($row->{name}, $force);
    if ( !$domain ) {
        return if $vm->is_local;
        $vm = $vm_local->new();
        $domain = $vm->search_domain($row->{name}, $force) or return;
    }
    if (!$id_vm) {
        $domain->_search_already_started();
        $domain->_check_clean_shutdown()  if $domain->domain && !$domain->is_active;
    }
    $domain->_insert_db_extra() if $domain && !$domain->is_known_extra();
    return $domain;
}

=head2 is_known

Returns if the domain is known in Ravada.

=cut

sub is_known {
    my $self = shift;
    return 1    if $self->_select_domain_db(name => $self->name);
    return 0;
}

=head2 is_known_extra

Returns if the domain has extra fields information known in Ravada.

=cut

sub is_known_extra {
    my $self = shift;

    my $sth = $$CONNECTOR->dbh->prepare("SELECT id FROM domains_".lc($self->type)
        ." WHERE id_domain=?");
    $sth->execute($self->id);
    my ($id) = $sth->fetchrow;
    return 1 if $id;
    return 0;
}

=head2 start_time

Returns the last time (epoch format in seconds) the
domain was started.

=cut

sub start_time {
    my $self = shift;
    return $self->_data('start_time');
}

sub _select_domain_db {
    my $self = shift;
    my %args = @_;

    _init_connector();

    if (!keys %args) {
        my $id;
        eval { $id = $self->id  };
        if ($id) {
            %args =( id => $id );
        } else {
            %args = ( name => $self->name );
        }
    }
    my $table = ( delete $args{_table} or 'domains');

    my $sth = $$CONNECTOR->dbh->prepare(
        "SELECT * FROM $table WHERE ".join(",",map { "$_=?" } sort keys %args )
    );
    $sth->execute(map { $args{$_} } sort keys %args);
    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    my $data = "_data";
    $data = "_data_$table" if $table ne 'domains';
    $self->{$data} = $row;

    return $row if $row->{id};
}

sub _post_select_domain_db {
    my $self = shift;
    $self->description($self->{_data}->{description})
        if defined $self->{_data}->{description}
};

sub _prepare_base_db {
    my $self = shift;
    my @file_img = @_;

    if (!$self->_select_domain_db) {
        confess "CRITICAL: The data should be already inserted";
#        $self->_insert_db( name => $self->name, id_owner => $self->id_owner );
    }
    my $sth = $$CONNECTOR->dbh->prepare(
        "INSERT INTO file_base_images "
        ." (id_domain , file_base_img, target )"
        ." VALUES(?,?,?)"
    );
    for my $file_img (@file_img) {
        my $target;
        ($file_img, $target) = @$file_img if ref $file_img;
        $sth->execute($self->id, $file_img, $target );
    }
    $sth->finish;

    $sth = $$CONNECTOR->dbh->prepare(
        "UPDATE domains SET is_base=1 "
        ." WHERE id=?");
    $sth->execute($self->id);
    $sth->finish;

    $self->_select_domain_db();
}

sub _set_spice_password {
    my $self = shift;
    my $password = shift;

    my $sth = $$CONNECTOR->dbh->prepare(
       "UPDATE domains set spice_password=?"
       ." WHERE id=?"
    );
    $sth->execute($password, $self->id);
    $sth->finish;

    $self->{_data}->{spice_password} = $password;
}

=head2 spice_password

Returns the password defined for the spice viewers

=cut

sub spice_password {
    my $self = shift;
    return $self->_data('spice_password');
}

=head2 display_file

Returns a file with the display information. Defaults to spice.

=cut

sub display_file($self,$user) {
    return $self->_display_file_spice($user);
}

# taken from isard-vdi thanks to @tuxinthejungle Alberto Larraz
sub _display_file_spice($self,$user) {

    my ($ip,$port) = $self->display($user) =~ m{spice://(\d+\.\d+\.\d+\.\d+):(\d+)};

    die "I can't find ip port in ".$self->display   if !$ip ||!$port;

    my $ret =
        "[virt-viewer]\n"
        ."type=spice\n"
        ."host=$ip\n";
    if ($self->tls) {
        $ret .= "tls-port=%s\n";
    } else {
        $ret .= "port=$port\n";
    }
    $ret .="password=%s\n"  if $self->spice_password();

    $ret .=
        "fullscreen=1\n"
        ."title=".$self->name." - Press SHIFT+F12 to exit\n"
        ."enable-smartcard=0\n"
        ."enable-usbredir=1\n"
        ."enable-usb-autoshare=1\n"
        ."delete-this-file=1\n";

    $ret .=";" if !$self->tls;
    $ret .= "tls-ciphers=DEFAULT\n"
        .";host-subject=O=".$ip.",CN=?\n";

    $ret .=";"  if !$self->tls;
    $ret .="ca=CA\n"
        ."release-cursor=shift+f11\n"
        ."toggle-fullscreen=shift+f12\n"
        ."secure-attention=ctrl+alt+end\n";
    $ret .=";" if !$self->tls;
    $ret .="secure-channels=main;inputs;cursor;playback;record;display;usbredir;smartcard\n";

    return $ret;
}

=head2 info

Return information about the domain.

=cut

sub info($self, $user) {
    my $info = {
        id => $self->id
        ,name => $self->name
        ,is_base => $self->is_base
        ,is_active => $self->is_active
        ,spice_password => $self->spice_password
        ,description => $self->description
        ,msg_timeout => ( $self->_msg_timeout or undef)
        ,has_clones => ( $self->has_clones or undef)
        ,needs_restart => ( $self->needs_restart or 0)
    };
    eval {
        $info->{display_url} = $self->display($user)    if $self->is_active;
    };
    die $@ if $@ && $@ !~ /not allowed/i;
    if (!$info->{description} && $self->id_base) {
        my $base = Ravada::Front::Domain->open($self->id_base);
        $info->{description} = $base->description;
    }
    if ($self->is_active) {
        my $display = $self->display($user);
        my ($local_ip, $local_port) = $display =~ m{\w+://(.*):(\d+)};
        $info->{display_ip} = $local_ip;
        $info->{display_port} = $local_port;
    }
    $info->{hardware} = $self->get_controllers();

    return $info;
}

sub _msg_timeout($self) {
    return if !$self->run_timeout;
    my $msg_timeout = '';

    for my $request ( $self->list_all_requests ) {
        if ( $request->command =~ 'shutdown' ) {
            my $t1 = Time::Piece->localtime($request->at_time);
            my $t2 = localtime();

            $msg_timeout = " in ".($t1 - $t2)->pretty;
        }
    }
    return $msg_timeout;
}

sub _insert_db {
    my $self = shift;
    my %field = @_;

    _init_connector();

    for (qw(name id_owner)) {
        confess "Field $_ is mandatory ".Dumper(\%field)
            if !exists $field{$_};
    }

    my ($vm) = ref($self) =~ /.*\:\:(\w+)$/;
    confess "Unknown domain from ".ref($self)   if !$vm;
    $field{vm} = $vm;
    $self->{_data}->{name} = $field{name}   if $field{name};

    my $query = "INSERT INTO domains "
            ."(" . join(",",sort keys %field )." )"
            ." VALUES (". join(",", map { '?' } keys %field )." ) "
    ;
    my $sth = $$CONNECTOR->dbh->prepare($query);
    eval { $sth->execute( map { $field{$_} } sort keys %field ) };
    if ($@) {
        #warn "$query\n".Dumper(\%field);
        confess $@;
    }
    $sth->finish;

    $sth = $$CONNECTOR->dbh->prepare(
        "UPDATE domains set internal_id=? "
        ." WHERE id=?"
    );
    $sth->execute($self->internal_id, $self->id);
    $sth->finish;

    $self->_insert_db_extra();
}

sub _insert_db_extra($self) {
    return if $self->is_known_extra();

    my $sth = $$CONNECTOR->dbh->prepare("INSERT INTO domains_".lc($self->type)
        ." ( id_domain ) VALUES (?) ");
    $sth->execute($self->id);
    $sth->finish;

}

=head2 pre_remove

Code to run before removing the domain. It can be implemented in each domain.
It is not expected to run by itself, the remove function calls it before proceeding.

    $domain->pre_remove();  # This isn't likely to be necessary
    $domain->remove();      # Automatically calls the domain pre_remove method

=cut

sub pre_remove { }

sub _pre_remove_domain($self, $user, @) {

    eval { $self->id };
    warn $@ if $@;

    $self->_allow_remove($user);
    $self->is_volatile()        if $self->is_known || $self->domain;
    $self->list_disks()         if ($self->is_known && $self->is_known_extra)
    || $self->domain ;
    $self->pre_remove();
    $self->_remove_iptables()   if $self->is_known();
}

sub _after_remove_domain {
    my $self = shift;
    my ($user, $cascade) = @_;

    $self->_remove_iptables(user => $user);
    $self->_remove_domain_cascade($user)   if !$cascade;

    if ($self->is_known && $self->is_base) {
        $self->_do_remove_base(@_);
        $self->_remove_files_base();
    }
    return if !$self->{_data};
    $self->_finish_requests_db();
    $self->_remove_base_db();
    $self->_remove_domain_db();
}

# removes domain in other VMs
sub _remove_domain_cascade($self,$user, $cascade = 1) {

    return if !$self->_vm;
    my $domain_name = $self->name or confess "Unknown my self name $self ".Dumper($self->{_data});

    my $sth = $$CONNECTOR->dbh->prepare("SELECT id,name FROM vms WHERE is_active=1");
    my ($id, $name);
    $sth->execute();
    $sth->bind_columns(\($id, $name));
    while ($sth->fetchrow) {
        next if $id == $self->_vm->id;
        my $vm = Ravada::VM->open($id);
        my $domain = $vm->search_domain($domain_name) or next;
        $domain->remove($user, $cascade);
    }
}

sub _remove_domain_db {
    my $self = shift;

    $self->_select_domain_db or return;

    my $id = $self->{_data}->{id} or return;
    my $type = $self->type;
    my $sth = $$CONNECTOR->dbh->prepare("DELETE FROM domains "
        ." WHERE id=?");
    $sth->execute($id);
    $sth->finish;

    $sth = $$CONNECTOR->dbh->prepare("DELETE FROM domains_".lc($type)
        ." WHERE id=?");
    $sth->execute($id);
    $sth->finish;

}

sub _finish_requests_db {
    my $self = shift;

    return if !$self->{_data}->{id};
    $self->_select_domain_db or return;

    my $id = $self->id;
    my $type = $self->type;
    my $sth = $$CONNECTOR->dbh->prepare("UPDATE requests "
        ." SET status='done' "
        ." WHERE id_domain=? AND status = 'requested' ");
    $sth->execute($id);
    $sth->finish;
}

sub _remove_files_base {
    my $self = shift;

    for my $file ( $self->list_files_base ) {
        unlink $file or die "$! $file" if -e $file;
    }
}


sub _remove_id_base {

    my $self = shift;

    my $sth = $$CONNECTOR->dbh->prepare(
        "UPDATE domains set id_base=NULL "
        ." WHERE id=?"
    );
    $sth->execute($self->id);
    $sth->finish;
}

=head2 is_base
Returns true or  false if the domain is a prepared base
=cut

sub is_base {
    my $self = shift;
    my $value = shift;

    $self->_select_domain_db or return 0;

    if (defined $value ) {
        my $sth = $$CONNECTOR->dbh->prepare(
            "UPDATE domains SET is_base=? "
            ." WHERE id=?");
        $sth->execute($value, $self->id );
        $sth->finish;

        return $value;
    }
    my $ret = $self->_data('is_base');
    $ret = 0 if $self->_data('is_base') =~ /n/i;

    return $ret;
};

=head2 is_locked
Shows if the domain has running or pending requests. It could be considered
too as the domain is busy doing something like starting, shutdown or prepare base.
Returns true if locked.
=cut

sub is_locked {
    my $self = shift;

    $self->_init_connector() if !defined $$CONNECTOR;

    my $sth = $$CONNECTOR->dbh->prepare("SELECT id,at_time FROM requests "
        ." WHERE id_domain=? AND status <> 'done'");
    $sth->execute($self->id);
    my ($id, $at_time) = $sth->fetchrow;
    $sth->finish;

    return 0 if $at_time && $at_time - time > 1;
    return ($id or 0);
}

=head2 id_owner
Returns the id of the user that created this domain
=cut

sub id_owner {
    my $self = shift;
    return $self->_data('id_owner',@_);
}

=head2 id_base
Returns the id from the base this domain is based on, if any.
=cut

sub id_base {
    my $self = shift;
    return $self->_data('id_base',@_);
}

=head2 vm
Returns a string with the name of the VM ( Virtual Machine ) this domain was created on
=cut


sub vm {
    my $self = shift;
    return $self->_data('vm');
}

=head2 clones
Returns a list of clones from this virtual machine
    my @clones = $domain->clones
=cut

sub clones {
    my $self = shift;

    _init_connector();

    my $sth = $$CONNECTOR->dbh->prepare("SELECT id, name FROM domains "
            ." WHERE id_base = ? AND (is_base=NULL OR is_base=0)");
    $sth->execute($self->id);
    my @clones;
    while (my $row = $sth->fetchrow_hashref) {
        # TODO: open the domain, now it returns only the id
        push @clones , $row;
    }
    return @clones;
}

=head2 has_clones
Returns the number of clones from this virtual machine
    my $has_clones = $domain->has_clones
=cut

sub has_clones {
    my $self = shift;

    _init_connector();

    return scalar $self->clones;
}


=head2 list_files_base
Returns a list of the filenames of this base-type domain
=cut

sub list_files_base {
    my $self = shift;
    my $with_target = shift;

    return if !$self->is_known();

    my $id;
    eval { $id = $self->id };
    return if $@ && $@ =~ /No DB info/i;
    die $@ if $@;

    my $sth = $$CONNECTOR->dbh->prepare("SELECT file_base_img, target "
        ." FROM file_base_images "
        ." WHERE id_domain=?");
    $sth->execute($self->id);

    my @files;
    while ( my ($img, $target) = $sth->fetchrow) {
        push @files,($img)          if !$with_target;
        push @files,[$img,$target]  if $with_target;
    }
    $sth->finish;
    return @files;
}

=head2 list_files_base_target

Returns a list of the filenames and targets of this base-type domain

=cut

sub list_files_base_target {
    return $_[0]->list_files_base("target");
}

=head2 can_screenshot
Returns wether this domain can take an screenshot.
=cut

sub can_screenshot {
    return 0;
}

sub _convert_png {
    my $self = shift;
    my ($file_in ,$file_out) = @_;

    my $in = Image::Magick->new();
    my $err = $in->Read($file_in);
    confess $err if $err;

    $in->Scale(width => 250, height => 188);
    $in->Write("png24:$file_out");

    chmod 0755,$file_out or die "$! chmod 0755 $file_out";
}

=head2 remove_base
Makes the domain a regular, non-base virtual machine and removes the base files.
=cut

sub remove_base {
    my $self = shift;
    return $self->_do_remove_base();
}

sub _do_remove_base {
    my $self = shift;
    $self->is_base(0);
    for my $file ($self->list_files_base) {
        next if ! -e $file;
        unlink $file or die "$! unlinking $file";
    }
    $self->storage_refresh()    if $self->storage();
}

sub _pre_remove_base {
    _allow_manage(@_);
    _check_has_clones(@_);
    $_[0]->spinoff_volumes();
}

sub _post_remove_base {
    my $self = shift;
    $self->_remove_base_db(@_);
    $self->_post_remove_base_domain();
    $self->_set_base_vm_db($self->_vm->id,1);
}

sub _pre_shutdown_domain {}

sub _post_remove_base_domain {}

sub _remove_base_db {
    my $self = shift;

    my $sth = $$CONNECTOR->dbh->prepare("DELETE FROM file_base_images "
        ." WHERE id_domain=?");

    $sth->execute($self->{_data}->{id});
    $sth->finish;

}

=head2 clone

Clones a domain

=head3 arguments

=over

=item user => $user : The user that owns the clone

=item name => $name : Name of the new clone

=back

=cut

sub clone {
    my $self = shift;
    my %args = @_;

    my $name = delete $args{name}
        or confess "ERROR: Missing domain cloned name";

    my $user = delete $args{user}
        or confess "ERROR: Missing request user";

    confess "ERROR: Clones can't be created in readonly mode"
        if $self->_vm->readonly();

    return $self->_copy_clone(@_)   if $self->id_base();

    my $request = delete $args{request};
    my $memory = delete $args{memory};

    confess "ERROR: Unknown args ".join(",",sort keys %args)
        if keys %args;

    my $uid = $user->id;

    if ( !$self->is_base() ) {
        $request->status("working","Preparing base")    if $request;
        $self->prepare_base($user)
    }

    my $id_base = $self->id;

    my @args_copy = ();
    push @args_copy, ( memory => $memory )      if $memory;
    push @args_copy, ( request => $request )    if $request;

    my $clone = $self->_vm->create_domain(
        name => $name
        ,id_base => $id_base
        ,id_owner => $uid
        ,vm => $self->vm
        ,_vm => $self->_vm
        ,@args_copy
    );
    return $clone;
}

sub _copy_clone($self, %args) {
    my $name = delete $args{name} or confess "ERROR: Missing name";
    my $user = delete $args{user} or confess "ERROR: Missing user";
    my $memory = delete $args{memory};
    my $request = delete $args{request};

    confess "ERROR: Unknown arguments ".join(",",sort keys %args)
        if keys %args;

    my $base = Ravada::Domain->open($self->id_base);

    my @copy_arg;
    push @copy_arg, ( memory => $memory ) if $memory;

    $request->status("working","Copying domain ".$self->name
        ." to $name")   if $request;

    my $copy = $self->_vm->create_domain(
        name => $name
        ,id_base => $base->id
        ,id_owner => $user->id
        ,_vm => $self->_vm
        ,@copy_arg
    );
    my @volumes = $self->list_volumes_target;
    my @copy_volumes = $copy->list_volumes_target;

    my %volumes = map { $_->[1] => $_->[0] } @volumes;
    my %copy_volumes = map { $_->[1] => $_->[0] } @copy_volumes;
    for my $target (keys %volumes) {
        copy($volumes{$target}, $copy_volumes{$target})
            or die "$! $volumes{$target}, $copy_volumes{$target}"
    }
    return $copy;
}

sub _post_pause {
    my $self = shift;
    my $user = shift;

    $self->_data(status => 'paused');
    $self->_remove_iptables();
}

sub _post_hibernate($self, $user) {
    $self->_data(status => 'hibernated');
    $self->_remove_iptables();
}

sub _pre_shutdown {
    my $self = shift;

    confess "ERROR: Missing arguments"  if scalar(@_) % 2;

    my %arg = @_;

    my $user = delete $arg{user};
    delete $arg{timeout};
    delete $arg{request};

    confess "Unknown args ".join(",",sort keys %arg)
        if keys %arg;

    $self->_allow_shutdown(@_);

    $self->_pre_shutdown_domain();

    if ($self->is_paused) {
        $self->resume(user => Ravada::Utils::user_daemon);
    }
    $self->list_disks;
}

sub _post_shutdown {
    my $self = shift;

    my %arg = @_;
    my $timeout = delete $arg{timeout};

    $self->_remove_iptables(%arg);
    $self->_data(status => 'shutdown')
        if $self->is_known && !$self->is_volatile && !$self->is_active;

    if ($self->is_known && $self->id_base) {
        for ( 1 ..  5 ) {
            last if !$self->is_active;
            sleep 1;
        }
        $self->clean_swap_volumes(@_) if !$self->is_active;
    }

    if (defined $timeout && !$self->is_removed && $self->is_active) {
        if ($timeout<2) {
            sleep $timeout;
            $self->_data(status => 'shutdown')    if !$self->is_active;
            return $self->_do_force_shutdown() if !$self->is_removed && $self->is_active;
        }

        my $req = Ravada::Request->force_shutdown_domain(
            id_domain => $self->id
               ,id_vm => $self->_vm->id
                , uid => $arg{user}->id
                 , at => time+$timeout 
        );
    }
    if ($self->is_volatile) {
        $self->_remove_temporary_machine();
        return;
    }
    # only if not volatile
    my $request;
    $request = $arg{request} if exists $arg{request};
    $self->_rsync_volumes_back( $request )
        if !$self->is_local && !$self->is_active && !$self->is_volatile;

    $self->needs_restart(0) if $self->is_known()
                                && $self->needs_restart()
                                && !$self->is_active;
    _test_iptables_jump();
}

sub _around_is_active($orig, $self) {
    return 0 if $self->is_removed;
    my $is_active = $self->$orig();
    return $is_active if $self->readonly
        || !$self->is_known
        || (defined $self->_data('id_vm') && (defined $self->_vm) && $self->_vm->id != $self->_data('id_vm'));

    my $status = 'shutdown';
    $status = 'active'  if $is_active;
    $status = 'hibernated'  if !$is_active && !$self->is_removed && $self->is_hibernated;
    $self->_data(status => $status);

    $self->needs_restart(0) if $self->needs_restart() && !$is_active;
    return $is_active;
}

sub _around_shutdown_now {
    my $orig = shift;
    my $self = shift;
    my $user = shift;

    $self->list_disks;
    $self->_pre_shutdown(user => $user);
    if ($self->is_active) {
        $self->$orig($user);
    }
    $self->_post_shutdown(user => $user)    if $self->is_known();
}

sub _around_name($orig,$self) {
    return $self->{_name} if $self->{_name};

    $self->{_name} = $self->{_data}->{name} if $self->{_data};
    $self->{_name} = $self->$orig()         if !$self->{_name};

    return $self->{_name};
}

=head2 can_hybernate

Returns wether a domain supports hybernation

=cut

sub can_hybernate { 0 };

=head2 can_hibernate

Returns wether a domain supports hibernation

=cut

sub can_hibernate {
    my $self = shift;
    return $self->can_hybernate();
};

=head2 add_volume_swap

Adds a swap volume to the virtual machine

Arguments:

    size => $kb
    name => $name (optional)

=cut

sub add_volume_swap {
    my $self = shift;
    my %arg = @_;

    $arg{name} = $self->name if !$arg{name};
    $self->add_volume(%arg, swap => 1);
}

sub _remove_iptables {
    my $self = shift;
    return if $>;

    my %args = @_;

    my $user = delete $args{user};
    my $port = delete $args{port};

    delete $args{request};

    confess "ERROR: Unknown args ".Dumper(\%args)    if keys %args;

    my $sth = $$CONNECTOR->dbh->prepare(
        "UPDATE iptables SET time_deleted=?"
        ." WHERE id=?"
    );
    my @iptables;
    push @iptables, ( $self->_active_iptables(id_domain => $self->id))  if $self->is_known();
    push @iptables, ( $self->_active_iptables(user => $user) )          if $user;
    push @iptables, ( $self->_active_iptables(port => $port) )          if $port;

    my %rule;
    for my $row (@iptables) {
        my ($id, $id_vm, $iptables) = @$row;
        next if !$id_vm;
        push @{$rule{$id_vm}},[ $id, $iptables ];
    }
    for my $id_vm (keys %rule) {
        my $vm = Ravada::VM->open($id_vm);
        for my $entry (@ {$rule{$id_vm}}) {
            my ($id, $iptables) = @$entry;
            $self->_delete_ip_rule($iptables, $vm);
            $sth->execute(Ravada::Utils::now(), $id);
        }
    }
}

sub _test_iptables_jump {
    my @cmd = ('iptables','-L','INPUT');
    my ($in, $out, $err);

    run3(\@cmd, \$in, \$out, \$err);

    my $count = 0;
    for my $line ( split /\n/,$out ) {
        $count++ if $line =~ /^RAVADA /;
    }
    return if !$count || $count == 1;
    warn "Expecting 0 or 1 RAVADA iptables jump, got: "    .($count or 0);
}


sub _remove_temporary_machine {
    my $self = shift;

    return if !$self->is_volatile;

    my %args = @_;

    return if !$self->is_known();
    return if !$self->is_volatile();

    my $user;
    eval { $user = Ravada::Auth::SQL->search_by_id($self->id_owner) };
    return if !$user;

    my $req= $args{request};
        $req->status(
            "removing"
            ,"Removing volatile machine ".$self->name)
                if $req;

        if ($self->is_removed) {
            $self->remove_disks();
            $self->_after_remove_domain();
        } else {
            $self->remove($user)    if $user->is_temporary;
        }
    $self->remove($user);

}

sub _post_resume {
    my $self = shift;
    return $self->_post_start(@_);
}

sub _post_start {
    my $self = shift;
    my %arg;

    if (scalar @_ % 2) {
        $arg{user} = $_[0];
    } else {
        %arg = @_;
    }

    $self->_data('status','active') if $self->is_active();
    my $sth = $$CONNECTOR->dbh->prepare(
        "UPDATE domains set start_time=? "
        ." WHERE id=?"
    );
    $sth->execute(time, $self->id);
    $sth->finish;

    $self->_data('internal_id',$self->internal_id);

    $self->_add_iptable(@_);
    $self->_update_id_vm();

    if ($self->run_timeout) {
        my $req = Ravada::Request->shutdown_domain(
            id_domain => $self->id
                , uid => $arg{user}->id
                 , at => time+$self->run_timeout
                 , timeout => 59
        );

    }
    $self->get_info();
    Ravada::Request->enforce_limits(at => time + 60)
        if !Ravada::Request::done_recently(undef, 60, 'enforce_limits');
    $self->post_resume_aux;
}

sub _update_id_vm($self) {
    my $sth = $$CONNECTOR->dbh->prepare(
        "UPDATE domains set id_vm=? where id = ?"
    );
    $sth->execute($self->_vm->id, $self->id);
    $sth->finish;

    $self->{_data}->{id_vm} = $self->_vm->id;
}

=head2 post_resume_aux

Method after resume

=cut

sub post_resume_aux {}

sub _add_iptable {
    my $self = shift;
    return if scalar @_ % 2;
    my %args = @_;

    my $remote_ip = $args{remote_ip} or return;

    my $user = $args{user} or confess "ERROR: Missing user";
    my $uid = $user->id;

    return if !$self->is_active;
    my $display = $self->display($user);
    my ($local_port) = $display =~ m{\w+://.*:(\d+)};
    $self->_remove_iptables( port => $local_port );

    my $local_ip = $self->_vm->ip;

    $self->_open_port($user, $remote_ip, $local_ip, $local_port);
    $self->_close_port($user, '0.0.0.0/0', $local_ip, $local_port);

}

sub _delete_ip_rule ($self, $iptables, $vm = $self->_vm) {

    my ($s, $d, $filter, $chain, $jump, $extra) = @$iptables;
    lock_hash %$extra;

    $s = undef if $s =~ m{^0\.0\.0\.0};
    $s .= "/32" if defined $s && $s !~ m{/};
    $d .= "/32" if defined $d && $d !~ m{/};

    my $iptables_list = $self->_vm->iptables_list();

    my $removed = 0;
    my $count = 0;
    for my $line (@{$iptables_list->{$filter}}) {
        my %args = @$line;
        next if $args{A} ne $chain;
        $count++;
        if((!defined $jump || ( exists $args{j} && $args{j} eq $jump ))
           && ( !defined $s || (exists $args{s} && $args{s} eq $s))
           && ( !defined $d || ( exists $args{d} && $args{d} eq $d))
           && ( $args{dport} eq $extra->{d_port}))
        {

           $self->_vm->run_command("/sbin/iptables", "-t", $filter, "-D", $chain, $count);
           $removed++;
           $count--;
        }

    }
    return $removed;
}
sub _open_port($self, $user, $remote_ip, $local_ip, $local_port, $jump = 'ACCEPT') {
    confess "local port undefined " if !$local_port;

    $self->_vm->create_iptables_chain($IPTABLES_CHAIN);

    my @iptables_arg = ($remote_ip
                        ,$local_ip, 'filter', $IPTABLES_CHAIN, $jump,
                        ,{'protocol' => 'tcp', 's_port' => 0, 'd_port' => $local_port});

    $self->_vm->iptables(
                A => $IPTABLES_CHAIN
                ,m => 'tcp'
                ,p => 'tcp'
                ,s => $remote_ip
                ,d => $local_ip
                ,dport => $local_port
                ,j => $jump
    );

    $self->_log_iptable(iptables => \@iptables_arg, user => $user, remote_ip => $remote_ip);

    if ($remote_ip eq '127.0.0.1') {
        my $remote_ip2 = $local_ip;
        if (!$self->_vm->is_local) {
            for my $node ($self->_vm->list_nodes) {
                if ($node->is_local) {
                    $remote_ip2 = $node->ip;
                    last;
                }
            }
        }
        $self->_vm->iptables(
                A => $IPTABLES_CHAIN
                ,m=> 'tcp'
                ,p => 'tcp'
                ,s => $remote_ip2
                ,d => $local_ip
                ,dport => $local_port
                ,j => $jump
        );
        $self->_log_iptable(
            iptables => [
                    $remote_ip2
                    , $local_ip, 'filter', $IPTABLES_CHAIN, $jump
                    ,{'protocol' => 'tcp', 's_port' => 0, 'd_port' => $local_port}
            ]
            , user => $user,remote_ip => $local_ip);
    }
}

sub _close_port($self, $user, $remote_ip, $local_ip, $local_port) {
    $self->_open_port($user, $remote_ip, $local_ip, $local_port,'DROP');
}

=head2 open_iptables

Open iptables for a remote client

=over

=item user

=item  remote_ip

=back

=cut

sub open_iptables {
    my $self = shift;

    my %args = @_;
    my $uid = delete $args{uid};
    my $user = delete $args{user};

    confess "ERROR: Supply either uid or user"  if !$uid && !$user;

    $user = Ravada::Auth::SQL->search_by_id($uid)   if $uid;
    confess "ERROR: User ".$user->name." not uid $uid"
        if $uid && $user->id != $uid;
    $args{user} = $user;
    delete $args{uid};

    $self->_data('client_status','connecting...');
    $self->_remove_iptables();

    if ( !$self->is_active ) {
        eval {
            $self->start(
                user => $user
            ,remote_ip => $args{remote_ip}
            );
        };
        die $@ if $@ && $@ !~ /already running/i;
    } else {
        Ravada::Request->enforce_limits( at => time + 60);
    }

    $self->_add_iptable(%args);
}

sub _log_iptable {
    my $self = shift;
    if (scalar(@_) %2 ) {
        carp "Odd number ".Dumper(\@_);
        return;
    }
    my %args = @_;

    my $remote_ip = delete $args{remote_ip} or confess "ERROR: remote_ip required";
    my $iptables  = delete $args{iptables}  or confess "ERROR: iptables required";
    my $user = delete $args{user};
    my $uid  = delete $args{uid};

    confess "ERROR: Unexpected arguments ".Dumper(\%args) if keys %args;
    confess "ERROR: Choose wether uid or user "
        if $user && $uid;
    confess "ERROR: Supply user or uid" if !defined $user && !defined $uid;

    lock_hash(%args);

    $uid = $user->id if !$uid;


    my $sth = $$CONNECTOR->dbh->prepare(
        "INSERT INTO iptables "
        ."(id_domain, id_user, remote_ip, time_req, iptables, id_vm)"
        ."VALUES(?, ?, ?, ?, ?, ?)"
    );
    $sth->execute($self->id, $uid, $remote_ip, Ravada::Utils::now()
        ,encode_json($iptables), $self->_vm->id);
    $sth->finish;

}

sub _active_iptables {
    my $self = shift;

    my %args = @_;

    my      $port = delete $args{port};
    my      $user = delete $args{user};
    my     $id_vm = delete $args{id_vm};
    my   $id_user = delete $args{id_user};
    my $id_domain = delete $args{id_domain};

    confess "ERROR: User id (".$user->id." is not $id_user "
        if $user && $id_user && $user->id ne $id_user;

    confess "ERROR: Unknown args ".Dumper(\%args)   if keys %args;

    $id_user = $user->id if $user;

    my @sql_fields;

    my $sql
        = "SELECT id, id_vm, iptables FROM iptables "
        ." WHERE time_deleted IS NULL";

    if ( $id_user ) {
        $sql .= "    AND id_user=? ";
        push @sql_fields,($id_user);
    }

    if ( $id_domain ) {
        $sql .= "    AND id_domain=? ";
        push @sql_fields,($id_domain);
    }
    if ($port && !$id_vm) {
        $id_vm = $self->_vm->id;
    }
    if ( $id_vm) {
        $sql .= "    AND id_vm=? ";
        push @sql_fields,($id_vm);
    }

    $sql .= " ORDER BY time_req DESC ";
    my $sth = $$CONNECTOR->dbh->prepare($sql);
    $sth->execute(@sql_fields);

    my @iptables;
    while (my ($id, $id_vm, $iptables) = $sth->fetchrow) {
        my $iptables_data = decode_json($iptables);
        next if $port && $iptables_data->[5]->{d_port} ne $port;
        push @iptables, [ $id, $id_vm, $iptables_data ];
    }
    return @iptables;
}

sub _check_duplicate_domain_name {
    my $self = shift;
# TODO
#   check name not in current domain in db
#   check name not in other VM domain
    $self->id();
}

sub _rename_domain_db {
    my $self = shift;
    my %args = @_;

    my $new_name = $args{name} or confess "Missing new name";

    my $sth = $$CONNECTOR->dbh->prepare("UPDATE domains set name=?"
                ." WHERE id=?");
    $sth->execute($new_name, $self->id);
    $sth->finish;
}

=head2 is_public

Sets or get the domain public

    $domain->is_public(1);

    if ($domain->is_public()) {
        ...
    }

=cut

sub is_public {
    my $self = shift;
    my $value = shift;

    _init_connector();
    if (defined $value) {
        my $sth = $$CONNECTOR->dbh->prepare("UPDATE domains set is_public=?"
                ." WHERE id=?");
        $sth->execute($value, $self->id);
        $sth->finish;
        $self->{_data}->{is_public} = $value;
    }
    return $self->_data('is_public');
}

=head2 is_volatile

Returns if the domain is volatile, so it will be removed on shutdown

=cut

sub is_volatile($self, $value=undef) {
    return $self->{_is_volatile} if exists $self->{_is_volatile}    && !defined $value;

    my $is_volatile = 0;
    if ($self->is_known) {
        $is_volatile = $self->_data('is_volatile', $value);
    } elsif ($self->domain) {
        $is_volatile = $self->is_persistent();
    }
    $self->{_is_volatile} = $is_volatile;
    return $is_volatile;
}

=head2 is_persistent

Returns true if the virtual machine is persistent. So it is not removed after
shut down.

=cut

sub is_persistent($self) {
    return !$self->{_is_volatile} if exists $self->{_is_volatile};
    return 0;
}

=head2 run_timeout

Sets or get the domain run timeout. When it expires it is shut down.

    $domain->run_timeout(60 * 60); # 60 minutes

=cut

sub run_timeout {
    my $self = shift;

    return $self->_data('run_timeout',@_);
}

#sub _set_data($self, $field, $value=undef) {
#    if (defined $value) {
#        warn "\t".$self->id." ".$self->name." $field = $value\n";
#        my $sth = $$CONNECTOR->dbh->prepare("UPDATE domains set $field=?"
#                ." WHERE id=?");
#        $sth->execute($value, $self->id);
#        $sth->finish;
#        $self->{_data}->{$field} = $value;
#
#        $self->_propagate_data($field,$value) if $PROPAGATE_FIELD{$field};
#    }
#    return $self->_data($field);
#}
sub _set_data($self, $field, $value) {
    return $self->_data($field, $value);
}

sub _propagate_data($self, $field, $value) {
    my $sth = $$CONNECTOR->dbh->prepare("UPDATE domains set $field=?"
                ." WHERE id_base=?");
    $sth->execute($value, $self->id);
    $sth->finish;
}

=head2 clean_swap_volumes

Check if the domain has swap volumes defined, and clean them

    $domain->clean_swap_volumes();

=cut

sub clean_swap_volumes {
    my $self = shift;
    for my $file ( $self->list_volumes) {
        $self->clean_disk($file)
            if $file =~ /\.SWAP\.\w+$/;
    }
}


sub _pre_rename {
    my $self = shift;

    my %args = @_;
    my $name = $args{name};
    my $user = $args{user};

    $self->_check_duplicate_domain_name(@_);

    $self->shutdown(user => $user)  if $self->is_active;
}

sub _post_rename {
    my $self = shift;
    my %args = @_;

    $self->_rename_domain_db(@_);
}

 sub _post_screenshot {
     my $self = shift;
     my ($filename) = @_;

     return if !defined $filename;

     my $sth = $$CONNECTOR->dbh->prepare(
         "UPDATE domains set file_screenshot=? "
         ." WHERE id=?"
     );
     $sth->execute($filename, $self->id);
     $sth->finish;
 }

=head2 get_controller

Calls the method to get the specified controller info

Attributes:
    name -> name of the controller type

=cut

sub get_controller {
	my $self = shift;
	my $name = shift;

    my $sub = $self->get_controller_by_name($name);
#    my $sub = $GET_CONTROLLER_SUB{$name};
    
    die "I can't get controller $name for domain ".$self->name
        if !$sub;

    return $sub->($self);
}

=head2 get_controllers

Returns a hashref of the hardware controllers for this virtual machine

=cut


sub get_controllers($self) {
    my $info;
    my %controllers = $self->list_controllers();
    for my $name ( sort keys %controllers ) {
        $info->{$name} = [$self->get_controller($name)];
    }
    return $info;
}

=head2 drivers

List the drivers available for a domain. It may filter for a given type.

    my @drivers = $domain->drivers();
    my @video_drivers = $domain->drivers('video');

=cut

sub drivers {
    my $self = shift;
    my $name = shift;
    my $type = shift;
    $type = $self->type         if $self && !$type;
    $type = $self->_vm->type    if $self && !$type;

    _init_connector();

    my $query = "SELECT id from domain_drivers_types ";

    my @sql_args = ();

    my @where;
    if ($name) {
        push @where,("name=?");
        push @sql_args,($name);
    }
    if ($type) {
        my $type2 = $type;
        if ($type =~ /qemu/) {
            $type2 = 'KVM';
        } elsif ($type =~ /KVM/) {
            $type2 = 'qemu';
        }
        push @where, ("( vm=? OR vm=?)");
        push @sql_args, ($type,$type2);
    }
    $query .= "WHERE ".join(" AND ",@where) if @where;
    my $sth = $$CONNECTOR->dbh->prepare($query);

    $sth->execute(@sql_args);

    my @drivers;
    while ( my ($id) = $sth->fetchrow) {
        push @drivers,Ravada::Domain::Driver->new(id => $id, domain => $self);
    }
    return $drivers[0] if !wantarray && $name && scalar@drivers< 2;
    return @drivers;
}

=head2 set_driver_id

Sets the driver of a domain given it id. The id must be one from
the table domain_drivers_options

    $domain->set_driver_id($id_driver);

=cut

sub set_driver_id {
    my $self = shift;
    my $id = shift;

    my $sth = $$CONNECTOR->dbh->prepare(
        "SELECT d.name,o.value "
        ." FROM domain_drivers_types d, domain_drivers_options o"
        ." WHERE d.id=o.id_driver_type "
        ."    AND o.id=?"
    );
    $sth->execute($id);

    my ($type, $value) = $sth->fetchrow;
    confess "Unknown driver option $id" if !$type || !$value;

    $self->set_driver($type => $value);
    $sth->finish;
}

sub remote_ip($self) {

    my $sth = $$CONNECTOR->dbh->prepare(
        "SELECT remote_ip, iptables FROM iptables "
        ." WHERE "
        ."    id_domain=?"
        ."    AND time_deleted IS NULL"
        ." ORDER BY time_req DESC "
    );
    $sth->execute($self->id);
    while ( my ($remote_ip, $iptables_json ) = $sth->fetchrow() ) {
        my $iptables = decode_json($iptables_json);
        next if $iptables->[4] ne 'ACCEPT';
        # TODO check multiple IPs
        return $remote_ip;
    }
    $sth->finish;
    return;

}

=head2 last_vm

Returns the last virtual machine manager on which this domain was
launched.

    my $vm = $domain->last_vm();

=cut

sub last_vm {
    my $self = shift;

    my $id_vm = $self->_data('id_vm');

    return if !$id_vm;

    return Ravada::VM->open($id_vm);
}

=head2 list_requests

Returns a list of pending requests from the domain. It won't show those requests
scheduled for later.

=cut

sub list_requests {
    my $self = shift;
    my $all = shift;

    my $sth = $$CONNECTOR->dbh->prepare(
        "SELECT * FROM requests WHERE id_domain = ? AND status <> 'done'"
    );
    $sth->execute($self->id);
    my @list;
    while ( my $req_data =  $sth->fetchrow_hashref ) {
        next if !$all && $req_data->{at_time} && $req_data->{at_time} - time > 1;
        push @list,($req_data);
    }
    $sth->finish;
    return scalar @list if !wantarray;
    return map { Ravada::Request->open($_->{id}) } @list;
}

=head2 list_all_requests

Returns a list of pending requests from the domain including those scheduled for later

=cut

sub list_all_requests {
    return list_requests(@_,'all');
}

=head2 get_driver

Returns the driver from a domain

Argument: name of the device [ optional ]
Returns all the drivers if not passwed

    my $driver = $domain->get_driver('video');

=cut

=head2 get_driver_id

Gets the value of a driver

Argument: name

    my $driver = $domain->get_driver('video');

=cut

sub get_driver_id($self, $name) {
    my $value = $self->get_driver($name);
    return if !defined $value;

    my $driver_type = $self->drivers($name) or confess "ERROR: Unknown drivers"
        ." of type '$name'";

    for my $option ($driver_type->get_options) {
        return $option->{id} if $option->{value} eq $value;
    }
    return;
}

sub _dbh {
    my $self = shift;
    _init_connector() if !$CONNECTOR || !$$CONNECTOR;
    return $$CONNECTOR->dbh;
}

=head2 set_option

Sets a domain option:

=over

=item * description

=item * run_timeout

=back


    $domain->set_option(description => 'Virtual Machine for ...');

=cut

sub set_option($self, $option, $value) {
    my %valid_option = map { $_ => 1 } qw( description run_timeout volatile_clones id_owner);
    die "ERROR: Invalid option '$option'"
        if !$valid_option{$option};

    return $self->_data($option, $value);
}

=head2 type

Returns the virtual machine type as a string.

=cut

sub type {
    my $self = shift;
    if (!exists $self->{_data} || !exists $self->{_data}->{vm}) {
        my ($type) = ref($self) =~ /.*::([a-zA-Z][a-zA-Z0-9]*)/;
        confess "Unknown type from ".ref($self) if !$type;
        return $type;
    }
    confess "Unknown vm ".Dumper($self->{_data})
        if !$self->_data('vm');
    return $self->_data('vm');
}

=head2 rsync

Synchronizes the volume data to a remote node.

Arguments: ( node => $node, request => $request, files => \@files )

=over

=item * node => Ravada::VM

=item * request => Ravada::Request ( optional )

=item * files => listref of files ( optional )

=back

When files is not specified it syncs the volumes and base volumes if any

=cut

sub rsync($self, @args) {

    my %args;
    if (scalar(@args) == 1 ) {
        $args{node} = $args[0];
    } else {
        %args = @args;
    }
    my    $node = ( delete $args{node} or $self->_vm );
    my   $files = delete $args{files};
    my $request = delete $args{request};

    confess "ERROR: Unkown args ".Dumper(\%args)    if keys %args;

    if (!$files ) {
        my @files_base;
        if ($self->is_base) {
            push @files_base,($self->list_files_base);
        }
        $files = [ $self->list_volumes(), @files_base ];
    }

    $request->status("working") if $request;
    if ($node->is_local ) {
        confess "Node ".$node->name." and current vm ".$self->_vm->name
                ." are both local "
                    if $self->_vm->is_local;
        $self->_vm->_connect_ssh()
            or confess "No Connection to ".$node->host;
    } else {
        $node->_connect_ssh()
            or confess "No Connection to ".$self->_vm->host;
    }
    my $rsync = File::Rsync->new(update => 1);
    for my $file ( @$files ) {
        $request->status("syncing","Tranferring $file to ".$node->host)
            if $request;
        my $src = $file;
        my $dst = 'root@'.$node->host.":".$file;
        if ($node->is_local) {
            $src = 'root@'.$self->_vm->host.":".$file;
            $dst = $file;
        }
        $rsync->exec(src => $src, dest => $dst);
    }
    if ($rsync->err) {
        $request->status("done",join(" ",@{$rsync->err}))   if $request;
        die $rsync->err;
    }
    $node->refresh_storage_pools();
}

sub _rsync_volumes_back($self, $request=undef) {
    my $rsync = File::Rsync->new(update => 1);
    for my $file ( $self->list_volumes() ) {
        $rsync->exec(src => 'root@'.$self->_vm->host.":".$file ,dest => $file );
        if ( $rsync->err ) {
            $request->status("done",join(" ",@{$rsync->err}))   if $request;
            last;
        }
    }
    $self->_vm->refresh_storage_pools();
}

sub _pre_migrate($self, $node) {

    $self->_check_equal_storage_pools($node);

    return if !$self->id_base;

    confess "ERROR: Active domains can't be migrated"   if $self->is_active;

    my $base = Ravada::Domain->open($self->id_base);
    confess "ERROR: base id ".$self->id_base." not found."  if !$base;

    die "ERROR: Base ".$base->name." files not migrated to ".$node->name
        if !$base->base_in_vm($node->id);

    for my $file ( $base->list_files_base ) {

        my ($name) = $file =~ m{.*/(.*)};

        my $vol_path = $node->search_volume_path($name);
        die "ERROR: $file not found in ".$node->host
            if !$vol_path;

        die "ERROR: $name found at $vol_path instead $file"
            if $vol_path ne $file;
    }

    $self->_set_base_vm_db($node->id,0);
}

sub _post_migrate($self, $node) {
    $self->_set_base_vm_db($node->id,1) if $self->is_base;
    $self->_vm($node);
    $self->_update_id_vm();

    # TODO: update db instead set this value
    $self->{_migrated} = 1;

}

sub _set_base_vm_db($self, $id_vm, $value) {
    my $is_base = $self->is_base && $self->base_in_vm($id_vm);
    if (!defined $is_base) {
        my $sth = $$CONNECTOR->dbh->prepare(
            "INSERT INTO bases_vm (id_domain, id_vm, enabled) "
            ." VALUES(?, ?, ?)"
        );
        $sth->execute($self->id, $id_vm, $value);
        $sth->finish;
    } else {
        my $sth = $$CONNECTOR->dbh->prepare(
            "UPDATE bases_vm SET enabled=?"
            ." WHERE id_domain=? AND id_vm=?"
        );
        $sth->execute($value, $self->id, $id_vm);
        $sth->finish;
    }
}

=head2 set_base_vm

    Prepares or removes a base in a virtual manager.

    $domain->set_base_vm(
        id_vm => $id_vm         # you can pass the id_vm
          ,vm => $vm            #    or the vm
        ,user => $user
       ,value => $value  # if it is 0, it removes the base
     ,request => $req
    );

=cut

sub set_base_vm($self, %args) {

    my $id_vm = delete $args{id_vm};
    my $value = delete $args{value};
    my $user  = delete $args{user};
    my $vm    = delete $args{vm};
    my $node  = delete $args{node};
    my $request = delete $args{request};

    confess "ERROR: Unknown arguments, valid are id_vm, value, user, node and vm "
        .Dumper(\%args) if keys %args;

    confess "ERROR: Supply either id_vm or vm argument"
        if (!$id_vm && !$vm && !$node) || ($id_vm && $vm) || ($id_vm && $node)
            || ($vm && $node);

    confess "ERROR: user required"  if !$user;

    $request->status("working") if $request;
    $vm = $node if $node;
    $vm = Ravada::VM->open($id_vm)  if !$vm;

    $value = 1 if !defined $value;

    if ($vm->is_local) {
        $self->_set_vm($vm,1);
        if (!$value) {
            $request->status("working","Removing base")     if $request;
            for my $vm_node ( $self->list_vms ) {
                $self->set_base_vm(vm => $vm_node, user => $user, value => 0
                    , request => $request) if !$vm_node->is_local;
            }
            $self->_set_base_vm_db($vm->id, $value);
            $self->remove_base($user);
        } else {
            $self->prepare_base($user);
            $request->status("working","Preparing base")    if $request;
        }
    } elsif ($value) {
        $request->status("working", "Syncing base volumes to ".$vm->host)
            if $request;
        $self->rsync(node => $vm, request => $request);
    }
    return $self->_set_base_vm_db($vm->id, $value);
}

sub migrate_base($self, %args) {
    return $self->set_base_vm(%args);
}

=head2 remove_base_vm

Removes a base in a Virtual Machine Manager node.

  $domain->remove_base_vm($vm, $user);

=cut

sub remove_base_vm($self, %args) {
    my $user = delete $args{user};
    my $vm = delete $args{vm};
    confess "ERROR: Unknown arguments ".join(',',sort keys %args).", valid are user and vm."
        if keys %args;

    return $self->set_base_vm(vm => $vm, user => $user, value => 0);
}

=head2 file_screenshot

Returns the file name where the domain screenshot has been stored

=cut

sub file_screenshot($self) {
    return $self->_data('file_screenshot');
}

sub _pre_clone($self,%args) {
    my $name = delete $args{name};
    my $user = delete $args{user};
    my $memory = delete $args{memory};
    delete $args{request};

    confess "ERROR: Missing clone name "    if !$name;
    confess "ERROR: Invalid name '$name'"   if $name !~ /^[a-z0-9_-]+$/i;

    confess "ERROR: Missing user owner of new domain"   if !$user;

    confess "ERROR: Unknown arguments ".join(",",sort keys %args)   if keys %args;
}

=head2 list_vms

Returns a list for virtual machine managers where this domain is base

=cut

sub list_vms($self) {
    confess "Domain is not base" if !$self->is_base;

    my $sth = $$CONNECTOR->dbh->prepare("SELECT id_vm FROM bases_vm WHERE id_domain=?");
    $sth->execute($self->id);
    my @vms;
    while (my $id_vm = $sth->fetchrow) {
        push @vms,(Ravada::VM->open($id_vm));
    }
    return @vms;
}

=head2 base_in_vm

Returns if this domain has a base prepared in this virtual manager

    if ($domain->base_in_vm($id_vm)) { ...

=cut

sub base_in_vm($self,$id_vm) {

    confess "ERROR: id_vm must be a number, it is '$id_vm'"
        if $id_vm !~ /^\d+$/;

    confess "ERROR: Domain ".$self->name." is not a base"
        if !$self->is_base;

    confess "Undefined id_vm " if !defined $id_vm;
    my $sth = $$CONNECTOR->dbh->prepare(
        "SELECT enabled FROM bases_vm "
        ." WHERE id_domain = ? AND id_vm = ?"
    );
    $sth->execute($self->id, $id_vm);
    my ( $enabled ) = $sth->fetchrow;
    $sth->finish;
#    return 1 if !defined $enabled
#        && $id_vm == $self->_vm->id && $self->_vm->host eq 'localhost';
    return $enabled;
}

=head2 is_local

Returns wether this domain is in the local host

=cut

sub is_local($self) {
    return $self->_vm->is_local();
}

=head2 internal_id

Returns the internal id of this domain as found in its Virtual Manager connection

=cut

sub internal_id {
    my $self = shift;
    return $self->id;
}

=head2 volatile_clones

Enables or disables a domain volatile clones feature. Volatile clones are
removed when shut down

=cut

sub volatile_clones($self, $value=undef) {
    return $self->_data('volatile_clones', $value);
}

=head2 status

Sets or gets the status of a virtual machine

  $machine->status('active');

Valid values are:

=over

=item * active

=item * down

=item * hibernated

=back

=cut

sub status($self, $value=undef) {
    confess "ERROR: the status can't be updated on read only mode."
        if $self->readonly;
    my %valid_value = map { $_ => 1 } qw(active shutdown);
    confess "ERROR: invalid value '$value'" if $value && !$valid_value{$value};
    return $self->_data('status', $value);
}

=head2 client_status

Returns the status of the viewer connection. The virtual machine must be
active, and the remote ip must be known.

Possible results:

=over

=item * connecting : set at the start of the virtual machine

=item * IP : known remote ip from the current connection

=item * disconnected : the remote client has been closed

=back

This method is used from higher level commands, for example, you can shut down
or hibernate all the disconnected virtual machines like this:

  # rvd_back --hibernate --disconnected
  # rvd_back --shutdown --disconnected

You could also set this command on a cron entry to run nightly, hourly or whenever
you find suitable.

=cut


sub client_status($self, $force=0) {
    return if !$self->is_active;
    return if !$self->remote_ip;

    return $self->_data('client_status')    if $self->readonly;

    my $time_checked = time - $self->_data('client_status_time_checked');
    if ( $time_checked < $TIME_CACHE_NETSTAT && !$force ) {
        return $self->_data('client_status');
    }

    my $status = $self->_client_connection_status( $force );
    $self->_data('client_status', $status);
    $self->_data('client_status_time_checked', time );

    return $status;
}

sub _run_netstat($self, $force=undef) {
    if (!$force && $self->_vm->{_netstat}
        && ( time - $self->_vm->{_netstat_time} < $TIME_CACHE_NETSTAT+1 ) ) {
        return $self->_vm->{_netstat};
    }
    my @cmd = ("netstat", "-tan");
    my ($in, $out, $err);
    run3(\@cmd, \$in, \$out, \$err);
    $self->_vm->{_netstat} = $out;
    $self->_vm->{_netstat_time} = time;

    return $out;
}

sub _client_connection_status($self, $force=undef) {
    #TODO: this should be run in the VM
    #       in develop release VM->run_command does exists
    my $display = $self->display(Ravada::Utils::user_daemon());
    my ($ip, $port) = $display =~ m{\w+://(.*):(\d+)};
    die "No ip in $display" if !$ip;

    my $netstat_out = $self->_run_netstat($force);
    my @out = split(/\n/,$netstat_out);
    for my $line (@out) {
        my @netstat_info = split(/\s+/,$line);
        if ( $netstat_info[3] eq $ip.":".$port ) {
            return 'connected' if $netstat_info[5] eq 'ESTABLISHED';
        }
    }
    return 'disconnected';
}

=head2 needs_restart

Returns true or false if the virtual machine needs to be restarted so some
hardware change can be applied.

=cut

sub needs_restart($self, $value=undef) {
    return $self->_data('needs_restart',$value);
}

sub _post_change_controller {
    my $self = shift;
    $self->needs_restart(1) if $self->is_active;
}
1;
