package File::Trash::FreeDesktop;

use 5.010;
use strict;
use warnings;

use Fcntl;

# VERSION

sub new {
    require Cwd;
    require File::HomeDir::FreeDesktop;
    require Sys::Filesystem::MountPoint;

    my ($class, %opts) = @_;

    my $home = File::HomeDir::FreeDesktop->my_home
        or die "Can't get homedir, ".
            "probably not a freedesktop-compliant environment?";
    $opts{_home} = Cwd::abs_path($home);
    $opts{_home_mp} = Sys::Filesystem::MountPoint::path_to_mount_point(
        $opts{_home});

    bless \%opts, $class;
}

sub _mk_trash {
    my ($self, $trash_dir) = @_;
    for ("", "/files", "/info") {
        my $d = "$trash_dir$_";
        unless (-d $d) {
            mkdir $d, 0700 or die "Can't mkdir $d: $!";
        }
    }
}

sub _home_trash {
    my ($self) = @_;
    "$self->{_home}/.local/share/Trash";
}

sub _select_trash {
    require Cwd;
    require Sys::Filesystem::MountPoint;

    my ($self, $file0, $create) = @_;
    my $afile = Cwd::abs_path($file0) or die "File doesn't exist: $file0";

    my $mp = Sys::Filesystem::MountPoint::path_to_mount_point($afile);
    my @trash_dirs;
    my $home_trash = $self->_home_trash;
    if ($self->{_home_mp} eq $mp) {
        @trash_dirs = ($self->_home_trash);
    } else {
        my $mp = $mp eq "/" ? "" : $mp; # prevent double-slash //
        @trash_dirs = ("$mp/.Trash-$>", "$mp/.Trash/$>");
    }

    for (@trash_dirs) {
        (-d $_) and return $_;
    }

    if ($create) {
        if ($trash_dirs[0] eq $home_trash) {
            $self->_mk_home_trash;
        } else {
            $self->_mk_trash($trash_dirs[0]);
        }
    }
    return $trash_dirs[0];
}

sub _mk_home_trash {
    my ($self) = @_;
    for (".local", ".local/share") {
        my $d = "$self->{_home}/$_";
        unless (-d $d) {
            mkdir $d or die "Can't mkdir $d: $!";
        }
    }
    $self->_mk_trash("$self->{_home}/.local/share/Trash");
}

sub list_trashes {
    require Cwd;
    require List::MoreUtils;
    require Sys::Filesystem;

    my ($self) = @_;

    my $sysfs = Sys::Filesystem->new;
    my @mp = $sysfs->filesystems;

    my @res = map { Cwd::abs_path($_) }
        grep {-d} (
            $self->_home_trash,
            (map { ("$_/.Trash-$>", "$_/.Trash/$>") } @mp)
        );

    List::MoreUtils::uniq(@res);
}

sub _parse_trashinfo {
    require Time::Local;

    my ($self, $content) = @_;
    $content =~ /\A\[Trash Info\]/m or return "No header line";
    my $res = {};
    $content =~ /^Path=(.+)/m or return "No Path line";
    $res->{path} = $1;
    $content =~ /^DeletionDate=(\d{4})-?(\d{2})-?(\d{2})T(\d\d):(\d\d):(\d\d)$/m
        or return "No/invalid DeletionDate line";
    $res->{deletion_date} = Time::Local::timelocal(
        $6, $5, $4, $3, $2-1, $1-1900)
        or return "Invalid date: $1-$2-$3T$4-$5-$6";
    $res;
}

sub list_contents {
    my ($self, $trash_dir0, $opts) = @_;
    $opts //= {};

    my @trash_dirs = $trash_dir0 ? ($trash_dir0) : ($self->list_trashes);
    my @res;
  L1:
    for my $trash_dir (@trash_dirs) {
        next unless -d $trash_dir;
        opendir my($dh), "$trash_dir/info"
            or die "Can't read trash info dir: $!";
        for my $e (readdir $dh) {
            next unless $e =~ /\.trashinfo$/;
            local $/;
            open my($fh), "$trash_dir/info/$e"
                or die "Can't open trash info file $e: $!";
            my $content = <$fh>;
            close $fh;
            my $pres = $self->_parse_trashinfo($content);
            die "Can't parse trash info file $e: $pres" unless ref($pres);
            if (defined $opts->{search_path}) {
                next unless $pres->{path} eq $opts->{search_path};
            }
            $pres->{trash_dir} = $trash_dir;
            $e =~ s/\.trashinfo//; $pres->{entry} = $e;
            push @res, $pres;
            last L1 if defined $opts->{search_path};
        }
    }

    @res;
}

sub trash {
    require Cwd;

    my ($self, $file0) = @_;

    my $afile = Cwd::abs_path($file0) or die "File does not exist: $file0";
    my $trash_dir = $self->_select_trash($afile, 1);

    # try to create info/NAME first
    my $name0 = $afile; $name0 =~ s!.*/!!; $name0 = "WTF" unless length($name0);
    my $name;
    my $fh;
    my $i = 1; my $limit = 1000;
    while (1) {
        $name = $name0 . ($i > 1 ? ".$i" : "");
        last if sysopen($fh, "$trash_dir/info/$name.trashinfo",
                        O_WRONLY | O_EXCL | O_CREAT);
        die "Can't create trash info file $name.trashinfo in $trash_dir: $!"
            if $i >= $limit;
        $i++;
    }

    my @t = localtime();
    my $ts = sprintf("%04d%02d%02dT%02d:%02d:%02d",
                     $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
    syswrite($fh, "[Trash Info]\nPath=$file0\nDeletionDate=$ts\n");
    close $fh or die "Can't write trash info for $name in $trash_dir: $!";

    unless (rename($afile, "$trash_dir/files/$name")) {
        unlink "$trash_dir/info/$name.trashinfo";
        die "Can't rename $afile to $trash_dir/files/$name: $!";
    }
}

sub recover {
    require Cwd;

    my ($self, $file, $trash_dir0) = @_;

    my @res = $self->list_contents($trash_dir0, {search_path=>$file});
    die "File not found in trash: $file" unless @res;

    my $trash_dir = $res[0]{trash_dir};
    unless (rename("$trash_dir/files/$res[0]{entry}", $file)) {
        die "Can't rename $trash_dir/files/$res[0]{entry} to $file: $!";
    }
    unlink("$trash_dir/info/$res[0]{entry}.trashinfo");
}

sub _erase {
    require Cwd;
    require File::Remove;

    my ($self, $file, $trash_dir) = @_;

    my @ct = $self->list_contents($trash_dir, {search_path=>$file});

    my @res;
    for (@ct) {
        my $f = "$_->{trash_dir}/info/$_->{entry}.trashinfo";
        unlink $f or die "Can't remove $f: $!";
        # XXX File::Remove interprets wildcard, what if filename contains
        # wildcard?
        File::Remove::remove(\1, "$_->{trash_dir}/files/$_->{entry}");
        push @res, $_->{path};
    }
    @res;
}

sub erase {
    my ($self, $file, $trash_dir) = @_;

    die "Please specify file" unless defined $file;
    $self->_erase($file, $trash_dir);
}

# XXX currently empty calls _erase, which parses .trashinfo files. this is
# useless overhead.
sub empty {
    my ($self, $trash_dir) = @_;

    $self->_erase(undef, $trash_dir);
}

1;
# ABSTRACT: Trash files

=head1 SYNOPSIS

 use File::Trash::FreeDesktop;

 my $trash = File::Trash::FreeDesktop->new;


=head1 DESCRIPTION

This module lets you trash/erase/restore files, also list the contents of trash
directories. This module follows the freedesktop.org trash specification [1],
with some notes/caveats:

=over 4

=item * For home trash, $HOME/.local/share/Trash is used instead of $HOME/.Trash

This is what KDE and GNOME use these days.

=item * Symlinks are currently not checked

The spec requires implementation to check whether trash directory is a symlink,
and refuse to use it in that case. This module currently does not do said
checking.

=item * Currently cross-device copying is not implemented/done

=item * Currently meant to be used by normal users, not administrators

This means, among others, this module only creates C<$topdir/.Trash-$uid>
instead of C<$topdir/.Trash>. And there are less paranoid checks being done.

=back


=head1 METHODS

=head2 $trash = File::Trash::FreeDesktop->new(%opts)

Constructor.

Currently there are no known options.

=head2 $trash->list_trashes() => LIST

List user's existing trash directories on the system.

Return a list of trash directories. Sample output:

 ("/home/steven/.local/share/Trash",
  "/tmp/.Trash-1000")

=head2 $trash->list_contents([$trash_dir]) => LIST

List contents of trash director(y|ies).

If $trash_dir is not specified, list contents from all existing trash
directories. Die if $trash_dir does not exist or inaccessible or corrupt. Return
a list of records like the sample below:

 ({entry=>"file1", path=>"/home/steven/file1", deletion_date=>1342061508},
  {entry=>"file1.2", path=>"/home/steven/sub/file1", deletion_date=>1342061580},
  {entry=>"dir1", path=>"/tmp/dir1", deletion_date=>1342061510})

=head2 $trash->trash($file)

Trash a file (move it into trash dir).

Will attempt to create C<$home/.local/share/Trash> (or C<$topdir/.Trash-$uid> if
file does not reside in the same filesystem/device as user's home). Will die if
attempt fails.

Will also die if moving file to trash (currently using rename()) fails.

=head2 $trash->recover($file[, $trash_dir])

Recover a file from trash.

Unless $trash_dir is specified, will search in all existing user's trash dirs.
Will die on errors (e.g. file is not found in trash).

=head2 $trash->erase($file[, $trash_dir]) => LIST

Erase (unlink()) a file in trash.

Unless $trash_dir is specified, will empty all existing user's trash dirs. Will
ignore if file does not exist in trash. Will die on errors.

Return list of files erased.

=head2 $trash->empty([$trash_dir]) => LIST

Empty trash.

Unless $trash_dir is specified, will empty all existing user's trash dirs. Will
die on errors.

Return list of files erased.


=head1 SEE ALSO

[1] http://freedesktop.org/wiki/Specifications/trash-spec

Related modules on CPAN:

=over 4

=item * L<Trash::Park>

Different trash structure (a single CSV file per trash to hold a list of deleted
files, files stored using original path structure, e.g. C<home/dir/file>). Does
not create per-filesystem trash.

=item * L<File::Trash>

Different trash structure (does not keep info file, files stored using original
path structure, e.g. C<home/dir/file>). Does not create per-filesystem trash.

=item * L<File::Remove>

File::Remove includes the trash() function which supports Win32, but no
undeletion function is provided at the time of this writing.

=back

=cut