package Ravada::VM::LXC;

use Carp qw(croak);
use Data::Dumper;
use Fcntl qw(:flock O_WRONLY O_EXCL O_CREAT);
use Hash::Util qw(lock_hash);
use IPC::Run3 qw(run3);
use Moose;
use Sys::Hostname;
use XML::LibXML;

#use Ravada::Domain::LXC;

with 'Ravada::VM';

sub connect {

#There are two user-space implementations of containers, each exploiting the same kernel
#features. Libvirt allows the use of containers through the LXC driver by connecting 
#to 'lxc:///'.
#We use the other implementation, called simply 'LXC', is not compatible with libvirt,
#but is more flexible with more userspace tools. 
#Use of libvirt-lxc is not generally recommended due to a lack of Apparmor protection 
#for libvirt-lxc containers.
#
#Reference: https://help.ubuntu.com/lts/serverguide/lxc.html#lxc-startup
#

}

sub create_domain {
 my $self = shift;
    my %args = @_;

    $args{active} = 1 if !defined $args{active};
    
    croak "argument name required"       if !$args{name};
    croak "argument id_iso or id_base required" 
        if !$args{id_iso} && !$args{id_base};

    my $domain;
    if ($args{id_iso}) {
        $domain = $self->_domain_create_from_iso(@_);
    } elsif($args{id_base}) {
        $domain = $self->_domain_create_from_base(@_);
    } else {
        confess "TODO";
    }

    return $domain;
}



sub create_volume {

 
}

sub list_domains {
	# my $self = shift;

 #    my @list;
 #    for my $name ($self->vm->list_all_domains()) {
 #        my $domain ;
 #        my $id;
 #        eval { $domain = Ravada::Domain::LXC->new(
 #                          domain => $name
 #                        ,storage => $self->storage_pool
 #                    );
 #             $id = $domain->id();
 #        };
 #        push @list,($domain) if $domain && $id;
 #    }
 #    return @list;
}

sub search_domain {

    # my $self = shift;
    # my $name = shift;

    # for ($self->vm->list_all_domains()) {
    #     next if $_->get_name ne $name;

    #     my $domain;
    #     eval {
    #         $domain = Ravada::Domain::LXC->new(
    #             domain => $_
    #             ,storage => $self->storage_pool
    #         );
    #     };
    #     warn $@ if $@;
    #     return $domain if $domain;
    # }
    # return;
}

sub search_domain_by_id {
   }


sub _domain_create_from_iso {
    # my $self = shift;
    # my %args = @_;

    # croak "argument id_iso required" 
    #     if !$args{id_iso};

    # die "Domain $args{name} already exists"
    #     if $self->search_domain($args{name});

    # my $vm = $self->vm;
    # my $storage = $self->storage_pool;

    # my $iso = $self->_search_iso($args{id_iso});

    
    return 
}

1;
