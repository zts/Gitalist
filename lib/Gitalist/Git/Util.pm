use MooseX::Declare;

class Gitalist::Git::Util {
    use File::Which;
    use Git::PurePerl;
    use IPC::Run qw(run start harness);
    use Symbol qw(geniosym);
    use MooseX::Types::Common::String qw/NonEmptySimpleStr/;
    use MooseX::Types::Moose qw/ArrayRef/;
    use Moose::Autobox;

    has repository => (
        isa => 'Gitalist::Git::Repository',
        handles => { gitdir => 'path' },
        is => 'bare', # No accessor
        weak_ref => 1, # Weak, you have to hold onto me.
        predicate => 'has_repository',
    );
    has _git      => ( isa => NonEmptySimpleStr, is => 'ro', lazy_build => 1 );
    sub _build__git {
        my $git = File::Which::which('git');

        if (!$git) {
            die <<EOR;
Could not find a git executable.
Please specify the which git executable to use in gitweb.yml
EOR
        }

        return $git;
    }

    has gpp      => (
        isa => 'Git::PurePerl', is => 'ro', lazy => 1,
        default => sub {
            my $self = shift;
            confess("Cannot get gpp without repository")
                unless $self->has_repository;
            Git::PurePerl->new(gitdir => $self->gitdir);
        },
    );

    method run_cmd (@args) {
        my @cmd = $self->make_git_cmd(@args);
        run \@cmd, \my($in, $out, $err);
        return $out;
    }

    method make_git_cmd (@args) {
        unshift @args, ('--git-dir' => $self->gitdir)
            if $self->has_repository;
        return ($self->_git, @args);
    }

    method run_cmd_fh (@git_args) {
        my @cmd = $self->make_git_cmd(@git_args);
        return $self->_real_run_cmd_fh( [\@cmd,] );
    }
    method run_cmd_gz_fh (@git_args) {
        my @cmd = $self->make_git_cmd(@git_args);
        return $self->_real_run_cmd_fh( [\@cmd, ['gzip']] );
    }
    method _real_run_cmd_fh (ArrayRef $commands) {
        my ($in, $out, $err) = (geniosym, geniosym, geniosym);
        # first command always gets stdin
        my @cmd = ( $commands->shift,
                    '<pipe', $in );
        # then pipes are added for subsequent commands
        if ($commands->length > 0) {
            @cmd = (@cmd, @{$commands->map(sub{ ('|', $_) })});
        }
        # stdout/stderr go after everything else
        my $harness = harness @cmd, '>pipe', $out,
              '2>pipe', $err;
        start $harness or die "cmd returned *?";
        return $out;
    }

    method run_cmd_list (@args) {
        my $cmdout = $self->run_cmd(@args);
        return $cmdout ? split(/\n/, $cmdout) : ();
    }

    method get_gpp_object (NonEmptySimpleStr $sha1) {
        return $self->gpp->get_object($sha1) || undef;
    }

} # end class

__END__

=head1 NAME

Gitalist::Git::Util - Class for utilities to run git or deal with Git::PurePerl

=head1 SEE ALSO

L<Git::PurePerl>.

=head1 AUTHORS

See L<Gitalist> for authors.

=head1 LICENSE

See L<Gitalist> for the license.

=cut

