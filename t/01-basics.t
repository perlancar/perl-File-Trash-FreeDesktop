#!perl

use 5.010;
use strict;
use warnings;

use Test::Exception;
use Test::More 0.96;

use File::chdir;
use File::Slurp;
use File::Temp qw(tempdir);
use File::Trash::FreeDesktop;
use SHARYANTO::File::Util qw(file_exists);

my $dir = tempdir(CLEANUP=>1);

$ENV{HOME} = $dir;
$CWD = $dir;
my $trash = File::Trash::FreeDesktop->new;

write_file("f1", "f1");
write_file("f2", "f2");
mkdir "sub";
write_file("sub/f1", "sub/f1");
write_file("sub/f2", "sub/f2");

my $ht = $trash->_home_trash;
diag "home trash is $ht";

subtest "trash" => sub {
    my $tfile = $trash->trash("f1");
    is($tfile, "$dir/.local/share/Trash/files/f1",
       "return value of trash()");
    ok((!(-e "f1")), "f1 removed");
    ok((-f ".local/share/Trash/info/f1.trashinfo"), "f1.trashinfo created");
    ok((-f ".local/share/Trash/files/f1"), "files/f1 created");

    $trash->trash("sub/f1");
    ok((!(-e "sub/f1")), "sub/f1 removed");
    ok((-f ".local/share/Trash/info/f1.2.trashinfo"), "f1.2.trashinfo created");
    ok((-f ".local/share/Trash/files/f1.2"), "files/f1.2 created");
};
# state at this point: T(f1 f2)

subtest "recover" => sub {
    $trash->recover("f1", $ht);
    ok((-f "f1"), "f1 recreated");
};
# state at this point: f1 T(f2)

subtest "erase" => sub {
    $trash->erase("sub/f1", $ht);
    ok(!(-e "sub/f1"), "sub/f1 removed");
    ok(!(-e ".local/share/Trash/info/f1.2.trashinfo"),"f1.2.trashinfo removed");
    ok(!(-e ".local/share/Trash/files/f1.2"), "files/f1.2 removed");
};
# state at this point: f1 T()

subtest "empty" => sub {
    $trash->trash("sub"); # also test removing directories
    $trash->empty($ht);
    ok(!(-e "sub"), "sub removed");
};
# state at this point: T()

subtest "trash nonexisting file" => sub {
    dies_ok  { $trash->trash("f3") } "trash nonexisting file -> dies";
    lives_ok { $trash->trash({on_not_found=>'ignore'}, "f3") }
        "on_not_found=ignore";
};
# state at this point: T()

subtest "recover nonexisting file" => sub {
    dies_ok  { $trash->recover("f3") } "recover nonexisting file -> dies";
    lives_ok { $trash->recover({on_not_found=>'ignore'}, "f3") }
        "on_not_found=ignore";
};
# state at this point: T()

write_file("f3", "f3a");
$trash->trash("f3");
write_file("f3", "f3b");
subtest "recover to an existing file" => sub {
    dies_ok { $trash->recover("f3") } "restore target already exists";
    is(scalar read_file("f3"), "f3b", "existing target not replaced");
    lives_ok { $trash->recover({on_target_exists=>'ignore'}, "f3") }
        "on_target_exists=ignore";
    is(scalar read_file("f3"), "f3b", "existing target not replaced");
    unlink "f3";
    lives_ok { $trash->recover("f3") } "can recover after target cleared";
    is(scalar read_file("f3"), "f3a", "the correct file recovered");
};
# state at this point: f3 T()

subtest "recover: mtime opt" => sub {
    write_file("f10", "f10.10");
    utime 1, 10, "f10";
    $trash->trash("f10");

    write_file("f10", "f10.20");
    utime 1, 20, "f10";
    $trash->trash("f10");

    dies_ok { $trash->recover({mtime=>30}, "f10") } "mtime not found -> dies";
    $trash->recover({mtime=>20}, "f10");
    is(scalar read_file("f10"), "f10.20", "f10 (mtime 20) recovered first");
    unlink "f10";
    $trash->recover({mtime=>10}, "f10");
    is(scalar read_file("f10"), "f10.10", "f10 (mtime 10) recovered");
    $trash->empty($ht);
};
# state at this point: f1 T()

subtest "recover: suffix opt" => sub {
    write_file("f10", "f10.a");
    $trash->trash({suffix=>"a"}, "f10");

    write_file("f10", "f10.b");
    $trash->trash({suffix=>"b"}, "f10");

    write_file("f10", "f10.another-b");
    dies_ok { $trash->recover({suffix=>"b"}, "f10") }
        "suffix already exists -> dies";
    unlink "f10";

    dies_ok { $trash->recover({suffix=>"c"}, "f10") }
        "suffix not found -> dies";
    $trash->recover({suffix=>"b"}, "f10");
    is(scalar read_file("f10"), "f10.b", "f10 (suffix b) recovered first");
    unlink "f10";
    $trash->recover({suffix=>"a"}, "f10");
    is(scalar read_file("f10"), "f10.a", "f10 (suffix a) recovered");
    $trash->empty($ht);
};
# state at this point: f1 T()

subtest "trash symlink" => sub {
    plan skip_all => "symlink() not available"
        unless eval { symlink "", ""; 1 };

    write_file("f21", "");
    symlink "f21", "s21";

    $trash->trash("s21");
    ok(!file_exists("s21"), "s21 deleted");
    ok( file_exists("f21"), "f21 not deleted");

    $trash->recover("s21");
    ok( file_exists("s21"), "s21 recovered");
    ok((-l "s21"), "s21 still a symlink");
    ok( file_exists("f21"), "f21 still not deleted");

    unlink "f21";
};
# state at this point: f1 T()

# TODO test: {trash,recover,erase} in $topdir/.Trash-$uid
# TODO test: list_trashes
# TODO test: list_contents for all trashes
# TODO test: empty for all trashes
# TODO test: test errors ...
#   - die on fail to create $topdir/.Trash-$uid
# TODO: deleting/listing/recovering a symlink
# TODO: deleting/listing/recovering a symlink with invalid target (-f false)

DONE_TESTING:
done_testing;
if (Test::More->builder->is_passing) {
    #diag "all tests successful, deleting test data dir";
    $CWD = "/" unless $ENV{NO_CLEANUP};
} else {
    diag "there are failing tests, not deleting test data dir ($dir)";
}
