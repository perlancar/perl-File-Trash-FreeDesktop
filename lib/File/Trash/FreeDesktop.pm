package File::Trash::FreeDesktop;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use Fcntl;
use SHARYANTO::File::Util qw(file_exists l_abs_path);

# VERSION

sub new {
    require File::HomeDir::FreeDesktop;
    require Sys::Filesystem::MountPoint;

    my ($class, %opts) = @_;

    my $home = File::HomeDir::FreeDesktop->my_home
        or die "Can't get homedir, ".
            "probably not a freedesktop-compliant environment?";
    $opts{_home} = l_abs_path($home);
    $opts{_home_mp} = Sys::Filesystem::MountPoint::path_to_mount_point(
        $opts{_home});

    bless \%opts, $class;
}

sub _mk_trash {
    my ($self, $trash_dir) = @_;
    $log->tracef("Creating trash directory %s ...", $trash_dir);
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

sub _select_trash {
    require Sys::Filesystem::MountPoint;

    my ($self, $file0) = @_;
    file_exists($file0) or die "File doesn't exist: $file0";
    my $afile = l_abs_path($file0);

    # since path_to_mount_point resolves symlink (sigh), we need to remove the
    # leaf. otherwise: /mnt/sym -> / will cause mount point to become / instead
    # of /mnt
    my $afile2 = $afile; $afile2 =~ s!/[^/]+\z!! if (-l $file0);
    my $mp = Sys::Filesystem::MountPoint::path_to_mount_point($afile2);

    my @trash_dirs;
    my $home_trash = $self->_home_trash;
    if ($self->{_home_mp} eq $mp) {
        @trash_dirs = ($self->_home_trash);
    } else {
        my $mp = $mp eq "/" ? "" : $mp; # prevent double-slash //
        @trash_dirs = ("$mp/.Trash-$>", "$mp/.Trash/$>");
    }
    #$log->tracef("mp=%s, afile=%s, trash_dirs = %s", $mp,$afile,\@trash_dirs);

    my ($sel, $create);
    for (@trash_dirs) {
        my @st = stat;
        if (-d _) {
            $sel = $_;
            # will we be able to write to this dir? (same owner or we are root).
            # we "create" anyway to fix missing files/ or info/ subdir (happens
            # from time to time for trash in /tmp).
            $create = $st[4] == $> || !$>;
            last;
        }
    }
    if (!$sel) {
        $sel = $trash_dirs[0];
        $create = 1;
    }
    $log->tracef("Selected trash for %s = %s", $afile, $sel);

    if ($create) {
        if ($sel eq $home_trash) {
            $self->_mk_home_trash;
        } else {
            $self->_mk_trash($sel);
        }
    }
    $log->tracef("Selected trash for %s = %s", $afile, $trash_dirs[0]);
    return $trash_dirs[0];
}

sub list_trashes {
    require List::MoreUtils;
    require Sys::Filesystem;

    my ($self) = @_;

    my $sysfs = Sys::Filesystem->new;
    my @mp = $sysfs->filesystems;

    my @res = map { l_abs_path($_) }
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
    my $self = shift;

    my $opts;
    if (ref($_[0]) eq 'HASH') {
        $opts = shift;
    } else {
        $opts = {};
    }
    my ($trash_dir0) = @_;

    my @trash_dirs = $trash_dir0 ? ($trash_dir0) : ($self->list_trashes);
    my @res;
  L1:
    for my $trash_dir (@trash_dirs) {
        next unless -d $trash_dir;
        next unless -d "$trash_dir/info";
        opendir my($dh), "$trash_dir/info"
            or die "Can't read trash info dir: $!";
        for my $e (readdir $dh) {
            next unless $e =~ /\.trashinfo$/;
            local $/;
            my $ifile = "$trash_dir/info/$e";
            open my($fh), $ifile or die "Can't open trash info file $e: $!";
            my $content = <$fh>;
            close $fh;
            my $pres = $self->_parse_trashinfo($content);
            die "Can't parse trash info file $e: $pres" unless ref($pres);
            if (defined $opts->{search_path}) {
                next unless $pres->{path} eq $opts->{search_path};
            }
            my $afile = "$trash_dir/files/$e"; $afile =~ s/\.trashinfo\z//;
            if (defined $opts->{mtime}) {
                my @st = lstat($afile);
                next unless !@st || $st[9] == $opts->{mtime};
            }
            if (defined $opts->{suffix}) {
                next unless $afile =~ /\.\Q$opts->{suffix}\E\z/;
            }
            $pres->{trash_dir} = $trash_dir;
            $e =~ s/\.trashinfo//; $pres->{entry} = $e;
            push @res, $pres;
            last L1 if defined $opts->{search_path};
        }
    }

    @res = sort {
        $a->{deletion_date} <=> $b->{deletion_date} ||
        $a->{entry} cmp $b->{entry}
    } @res;

    @res;
}

sub trash {
    my $self = shift;
    my $opts;
    if (ref($_[0]) eq 'HASH') {
        $opts = shift;
    } else {
        $opts = {};
    }
    $opts->{on_not_found} //= 'die';
    my ($file0) = @_;

    unless (file_exists $file0) {
        if ($opts->{on_not_found} eq 'ignore') {
            return undef;
        } else {
            die "File does not exist: $file0";
        }
    }
    my $afile = l_abs_path($file0);
    my $trash_dir = $self->_select_trash($afile);

    # try to create info/NAME first
    my $name0 = $afile; $name0 =~ s!.*/!!; $name0 = "WTF" unless length($name0);
    my $name;
    my $fh;
    my $i = 1; my $limit = defined($opts->{suffix}) ? 1 : 1000;
    my $tinfo;
    while (1) {
        $name = $name0 . (defined($opts->{suffix}) ? ".$opts->{suffix}" :
                              ($i > 1 ? ".$i" : ""));
        $tinfo = "$trash_dir/info/$name.trashinfo";
        last if sysopen($fh, $tinfo, O_WRONLY | O_EXCL | O_CREAT);
        die "Can't create trash info file $name.trashinfo in $trash_dir: $!"
            if $i >= $limit;
        $i++;
    }
    my $tfile = "$trash_dir/files/$name";

    my @t = localtime();
    my $ts = sprintf("%04d%02d%02dT%02d:%02d:%02d",
                     $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
    syswrite($fh, "[Trash Info]\nPath=$afile\nDeletionDate=$ts\n");
    close $fh or die "Can't write trash info for $name in $trash_dir: $!";

    $log->tracef("Trashing %s -> %s ...", $afile, $tfile);
    unless (rename($afile, $tfile)) {
        unlink "$trash_dir/info/$name.trashinfo";
        die "Can't rename $afile to $tfile: $!";
    }

    $tfile;
}

sub recover {
    my $self = shift;
    my $opts;
    if (ref($_[0]) eq 'HASH') {
        $opts = shift;
    } else {
        $opts = {};
    }
    $opts->{on_not_found}     //= 'die';
    $opts->{on_target_exists} //= 'die';
    my ($file0, $trash_dir0) = @_;

    if (file_exists($file0)) {
        if ($opts->{on_target_exists} eq 'ignore') {
            return 0;
        } else {
            die "Restore target already exists: $file0";
        }
    }
    my $afile = l_abs_path($file0);

    my @res = $self->list_contents({
        search_path => $afile,
        mtime       => $opts->{mtime},
        suffix      => $opts->{suffix},
    }, $trash_dir0);
    unless (@res) {
        if ($opts->{on_not_found} eq 'ignore') {
            return 0;
        } else {
            die "File not found in trash: $file0";
        }
    }

    my $trash_dir = $res[0]{trash_dir};
    my $ifile = "$trash_dir/info/$res[0]{entry}.trashinfo";
    my $tfile = "$trash_dir/files/$res[0]{entry}";
    $log->tracef("Recovering from trash %s -> %s ...", $tfile, $afile);
    unless (rename($tfile, $afile)) {
        die "Can't rename $tfile to $afile: $!";
    }
    unlink($ifile);
}

sub _erase {
    require File::Remove;

    my ($self, $file0, $trash_dir) = @_;
    my $afile = defined($file0) ? l_abs_path($file0) : undef;

    my @ct = $self->list_contents({search_path=>$afile}, $trash_dir);

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

 # list available (for the running user) trash directories
 my @trashes = $trash->list_trashes;

 # list the content of a trash directory
 my @content = $trash->list_contents("/tmp/.Trash-1000");

 # list the content of all available trash directories
 my @content = $trash->list_contents;

 # trash a file
 $trash->trash("/foo/bar");

 # specify some options when trashing
 $trash->trash({on_not_found=>'ignore'}, "/foo/bar");

 # recover a file from trash (untrash)
 $trash->recover('/foo/bar');

 # untrash a file from a specific trash directory
 $trash->recover('/tmp/file', '/tmp/.Trash-1000');

 # specify some options when untrashing
 $trash->recover({on_not_found=>'ignore', on_target_exists=>'ignore'}, '/path');

 # empty a trash directory
 $trash->empty("$ENV{HOME}/.local/share/Trash");

 # empty all available trashes
 $trash->empty;


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

It should not matter though, because trash directories are per-filesystem.

=back

Some other notes:

=over 4

=item *

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

 ({entry=>"file1", path=>"/home/steven/file1", deletion_date=>1342061508,
   trash_dir=>"/home/steven/.local/share/Trash"},
  {entry=>"file1.2", path=>"/home/steven/sub/file1", deletion_date=>1342061580,
   trash_dir=>"/home/steven/.local/share/Trash"},
  {entry=>"dir1", path=>"/tmp/dir1", deletion_date=>1342061510,
   trash_dir=>"/tmp/.Trash-1000"})

=head2 $trash->trash([\%opts, ]$file) => STR

Trash a file (move it into trash dir).

Will attempt to create C<$home/.local/share/Trash> (or C<$topdir/.Trash-$uid> if
file does not reside in the same filesystem/device as user's home). Will die if
attempt fails.

Will also die if moving file to trash (currently using rename()) fails.

Upon success, will return the location of the file in the trash dir (e.g.
C</tmp/.Trash-1000/files/foo>).

If first argument is a hashref, it will be accepted as options. Known options:

=over 4

=item * on_not_found => STR (default 'die')

Specify what to do when the file to be deleted is not found. The default is
'die', but can also be set to 'ignore' and return immediately.

=item * suffix => STR

Pick a suffix. Normally, file will be stored in C<files/ORIGNAME> inside trash
directory, or, if that file already exists, in C<files/ORIGNAME.1>,
C<files/ORIGNAME.2>, and so on. This setting overrides this behavior and picks
C<files/ORIGNAME.SUFFIX>. Can be used to identify and restore particular file
later. However, will die if file with that suffix already exists, so be sure to
pick a unique suffix.

=back


=head2 $trash->recover([\%opts, ]$file[, $trash_dir])

Recover a file from trash.

Unless $trash_dir is specified, will search in all existing user's trash dirs.
Will die on errors.

If first argument is a hashref, it will be accepted as options. Known options:

=over 4

=item * on_not_found => STR (default 'die')

Specify what to do when file is not found in the trash. The default is 'die',
but can also be set to 'ignore' and return immediately.

=item * on_target_exists => STR (default 'die')

Specify what to do when restore target already exists. The default is 'die', but
can also be set to 'ignore' and return immediately.

=item * mtime => INT

Only recover file if file's mtime is the one specified. This can be useful to
make sure that the file we recover is really the one that we trashed earlier,
especially if we trash several files with the same path.

(Ideally, instead of mtime we should use some unique ID that we write in the
.trashinfo file, but I fear that an extra parameter in .trashinfo file might
confuse other implementations.)

See also C<suffix>, which is the recommended way to identify and recover
particular file.

=item * suffix => STR

Only recover file having the specified suffix, chosen previously during trash().

=back

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
