use warnings;
use strict;

use Data::Dumper;
use Hash::Util qw(lock_hash);
use Test::More;

no warnings "experimental::signatures";
use feature qw(signatures);

use lib 't/lib';
use Test::Ravada;

init('t/etc/ravada_ldap_basic.conf');
clean();

sub _remove_bases(@bases) {
    for my $base (@bases) {
        for my $clone_data ($base->clones) {
            my $clone = Ravada::Domain->open($clone_data->{id});
            $clone->remove(user_admin);
        }
        my $id_domain = $base->id;
        $base->remove(user_admin);

        my $sth = connector->dbh->prepare(
            "SELECT * from domain_access"
            ." WHERE id_domain=?"
        );
        $sth->execute($id_domain);

        my $row = $sth->fetchrow_hashref;
        ok(!$row,"Expecting removed domain_access after remove domain : ".$id_domain
        ." ".Dumper($row));
        $sth->finish;
    }
}

sub test_access_by_group($vm) {
    my $base = create_domain($vm->type);
    $base->prepare_base(user_admin);
    $base->is_public(1);

    my $g_name = new_domain_name();
    my $group = Ravada::Auth::LDAP::search_group(name => $g_name);
    if (!$group) {
            Ravada::Auth::LDAP::add_group($g_name);
    }

    $base->grant_access(
        type => 'group'
        ,group => $g_name
    );
    my $user = create_user(new_domain_name(),$$);
    is($user->is_admin, 0 );

    my $list_bases = rvd_front->list_machines_user($user);
    is(scalar(@$list_bases),0) or exit;

    my $user_ldap0 = create_ldap_user(new_domain_name(), $$);
    my $user_ldap = Ravada::Auth::SQL->new(name => $user_ldap0->get_value('cn'));
    $list_bases = rvd_front->list_machines_user($user_ldap);
    is(scalar(@$list_bases),0) or exit;

    Ravada::Auth::LDAP::add_to_group($user_ldap->ldap_entry->dn, $g_name);

    $user_ldap->_load_allowed(1);
    $list_bases = rvd_front->list_machines_user($user_ldap);
    is(scalar(@$list_bases),1) or exit;

    $list_bases = rvd_front->list_machines_user(user_admin);
    is(scalar(@$list_bases),1) or exit;

    remove_domain($base);
}

sub test_access_by_agent($vm, $do_clones=0) {

    my $base = create_domain($vm->type);
    $base->prepare_base(user_admin);
    $base->is_public(1);

    my $clone = $base->clone(
        name => new_domain_name
        ,user => user_admin
    );

    my $list_bases = rvd_front->list_machines_user(user_admin());
    is(scalar (@$list_bases), 1);

    is(scalar($base->list_access),0);

    my      $type = 'client';
    my     $value = ' Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:71.0) Gecko/20100101 Firefox/71.0';
    my $attribute = 'User-Agent';
    $base->grant_access(
              type => $type
        ,attribute => $attribute
            ,value => $value
    );
    is(scalar($base->list_access),2);
    is($base->access_allowed( $type => { $attribute => $value} ),1);
    is($base->access_allowed( $type => { $attribute => 'fail'} ),0) or exit;
    $list_bases = rvd_front->list_machines_user(user_admin());
    is(scalar (@$list_bases), 0) or exit;

    $list_bases = rvd_front->list_machines_user(user_admin(), { $type =>{ $attribute => $value }});
    is(scalar (@$list_bases), 1);

    _remove_bases($base);
}


sub test_access_by_lang($vm, $do_clones=0) {

    my $base = create_domain($vm->type);
    $base->prepare_base(user_admin);
    $base->is_public(1);

    my $clone = $base->clone(
        name => new_domain_name
        ,user => user_admin
    );

    my $list_bases = rvd_front->list_machines_user(user_admin());
    is(scalar (@$list_bases), 1);

    is(scalar($base->list_access),0);

    my      $type = 'client';
    my     $value = 'ca-ca';
    my $attribute = 'Accept-Language';
    $base->grant_access(
              type => $type
        ,attribute => $attribute
            ,value => $value
    );
    is(scalar($base->list_access),2);
    is($base->access_allowed( $type => { $attribute => $value} ),1);
    is($base->access_allowed( $type => { $attribute => 'fail'} ),0) or exit;
    $list_bases = rvd_front->list_machines_user(user_admin());
    is(scalar (@$list_bases), 0) or exit;

    $list_bases = rvd_front->list_machines_user(user_admin(), { $type =>{ $attribute => $value }});
    is(scalar (@$list_bases), 1);

    is($base->access_allowed( $type => { $attribute => 'ca-ca,en-US;q=0.7,en;q=0.3'} ),1);

    _remove_bases($base);
}

sub test_access_by_encoding($vm) {

    my $base = create_domain($vm->type);
    $base->prepare_base(user_admin);
    $base->is_public(1);

    my $clone = $base->clone(
        name => new_domain_name
        ,user => user_admin
    );

    my      $type = 'client';
    my     $value = 'gzip';
    my    $value2 = 'gzip,deflate';
    my $attribute = 'Accept-Encoding';
    $base->grant_access(
              type => $type
        ,attribute => $attribute
            ,value => $value
    );
    is(scalar($base->list_access),2);
    is($base->access_allowed( $type => { $attribute => $value} ),1);
    is($base->access_allowed( $type => { $attribute => $value2} ),1) or exit;
    is($base->access_allowed( $type => { $attribute => 'fail'} ),0) or exit;
    my $list_bases = rvd_front->list_machines_user(user_admin());
    is(scalar (@$list_bases), 0) or exit;

    $list_bases = rvd_front->list_machines_user(user_admin(), { $type =>{ $attribute => $value }});
    is(scalar (@$list_bases), 1);

    $list_bases = rvd_front->list_machines_user(user_admin(), { $type =>{ $attribute => $value2 }});
    is(scalar (@$list_bases), 1);

    _remove_bases($base);
}

sub test_access_by_lang_2_entries($vm, $do_clones=0) {

    my $base = create_domain($vm->type);
    $base->prepare_base(user_admin);
    $base->is_public(1);

    my $clone = $base->clone(
        name => new_domain_name
        ,user => user_admin
    );

    my $list_bases = rvd_front->list_machines_user(user_admin());
    is(scalar (@$list_bases), 1);

    my      $type = 'client';
    my     $value = 'ca-ca';
    my $attribute = 'HTTP_ACCEPT_LANGUAGE';

    my %access_data = (
        $type => { $attribute => [$value,'whoaa'] }
    );
    $base->grant_access(
              type => $type
        ,attribute => $attribute
            ,value => $value
    );
    is($base->access_allowed( %access_data ),1) or exit;
    $list_bases = rvd_front->list_machines_user(user_admin());
    is(scalar (@$list_bases), 0) or exit;

    $list_bases = rvd_front->list_machines_user(user_admin(), \%access_data );
    is(scalar (@$list_bases), 1) or exit;

    _remove_bases($base);
}

sub test_access_by_lang_default($vm, $default, $do_clones=0) {

    my $base = create_domain($vm->type);
    $base->prepare_base(user_admin);
    $base->is_public(1);

    my $clone = $base->clone(
        name => new_domain_name
        ,user => user_admin
    );

    my $list_bases = rvd_front->list_machines_user(user_admin());
    is(scalar (@$list_bases), 1);

    my      $type = 'client';
    my     $value = 'ca-ca';
    my $attribute = 'HTTP_ACCEPT_LANGUAGE';
    $base->grant_access(
              type => $type
        ,attribute => $attribute
            ,value => $value
    );

    $base->grant_access(
              type => $type
        ,attribute => $attribute
            ,value => '*'
            , last => 1
          ,allowed => $default
    );


    is($base->access_allowed( $type => { $attribute => $value} ),1) or exit;
    is($base->access_allowed( $type => { $attribute => "fail"} ),$default) or exit;
    is($base->access_allowed( ), $default) or exit;
    $list_bases = rvd_front->list_machines_user(user_admin());

    is(scalar (@$list_bases), $default, "Failed on default=$default") or exit;

    $list_bases = rvd_front->list_machines_user(user_admin(), { $type =>{ $attribute => $value }});
    is(scalar (@$list_bases), 1) or exit;

    my @access = $base->list_access();
    is($access[-1]->{value},'*');

    $base->grant_access(
              type => $type
        ,attribute => $attribute
            ,value => 'another'
    );

    @access = $base->list_access();
    is($access[-1]->{value},'*') or exit;

    _remove_bases($base);
}

sub test_move($vm) {
    my $base = create_domain($vm->type);

    my      $type = 'client';
    my     $value = 'ca-ca';
    my $attribute = 'HTTP_ACCEPT_LANGUAGE';
    my $attribute2 = 'HTTP_ACCEPT_LANGUAGE2';

    $base->grant_access(
              type => $type
        ,attribute => $attribute
            ,value => $value
             ,last => 1
    );
    my %client = (
        $attribute => $value
        ,$attribute2 => $value
    );

    is($base->access_allowed( $type => \%client ),1);

    $base->grant_access(
              type => $type
        ,attribute => $attribute2
            ,value => $value
            , last => 1
          ,allowed => 0
    );

    is($base->access_allowed( $type => \%client ),1) or exit;
    my @access = $base->list_access();
    my ($id1, $id2) = ($access[0]->{id}, $access[1]->{id});

    $base->move_access($id2, -1);
    @access = $base->list_access();
    is($access[0]->{id}, $id2);
    @access = $base->list_access();

    is($base->access_allowed( $type => \%client ),0) or exit;

    _remove_bases($base);
}

sub test_maintenance() {
    is(rvd_front->is_in_maintenance(),0);
    my $settings = rvd_front->settings_global();
    is($settings->{frontend}->{maintenance}->{value},0);
    is($settings->{frontend}->{maintenance_start}->{value},'');
    is($settings->{frontend}->{maintenance_end}->{value}, '');

    my $arg = {
        frontend => { maintenance => {
                id => $settings->{frontend}->{maintenance}->{id}
                ,value => 1
            }
            ,maintenance_start => {
                id => $settings->{frontend}->{maintenance_start}->{id}
                ,value => '2020-02-13 13:30'
            }
            ,maintenance_end => {
                id => $settings->{frontend}->{maintenance_end}->{id}
                ,value => '2099-02-13 13:30'
            }
        }
    };
    my $reload = 0;
    rvd_front->update_settings_global($arg,user_admin, \$reload);
    is(rvd_front->is_in_maintenance(),1);
    $settings = rvd_front->settings_global();
    is($settings->{frontend}->{maintenance}->{value},1);
    is($reload, 0);

    #start tomorrow
    $arg->{frontend}->{maintenance_start}->{value} = '2090-02-14 13:30';
    rvd_front->update_settings_global($arg,user_admin, \$reload);
    is(rvd_front->is_in_maintenance(),0);

    $settings = rvd_front->settings_global();
    is($settings->{frontend}->{maintenance}->{value},1);

}

###########################################################################

for my $vm_name (reverse vm_names()) {
    my $vm = rvd_back->search_vm($vm_name);

    SKIP: {

        my $msg = "SKIPPED: No virtual managers found";
        if ($vm && $vm_name =~ /kvm/i && $>) {
            $msg = "SKIPPED: Test must run as root";
            $vm = undef;
        }
        skip($msg,10)   if !$vm;
        diag("Testing access restrictions in domain for $vm_name");

        test_access_by_group($vm);

        test_access_by_agent($vm);

        test_access_by_lang($vm);
        test_access_by_lang($vm, 1); # do clones too

        test_access_by_lang_2_entries($vm);
        test_access_by_lang_2_entries($vm, 1); # do clones too

        test_access_by_lang_default($vm, 0);
        test_access_by_lang_default($vm, 1, 1); # do clones too

        test_access_by_encoding($vm);

        test_move($vm);

    }
}
test_maintenance();

end();
done_testing();
