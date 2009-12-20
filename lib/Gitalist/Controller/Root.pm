package Gitalist::Controller::Root;

use Moose;
use Moose::Autobox;
use Sys::Hostname ();
use XML::Atom::Feed;
use XML::Atom::Entry;
use XML::RSS;
use XML::OPML::SimpleGen;

use Gitalist::Utils qw/ age_string /;

use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller' }

__PACKAGE__->config->{namespace} = '';

sub root : Chained('/') PathPart('') CaptureArgs(0) {}

sub _get_object {
  my($self, $c, $haveh) = @_;

  my $h = $haveh || $c->req->param('h') || '';
  my $f = $c->req->param('f');

  my $m = $c->stash->{Repository};
  my $pd = $m->path;

  # Either use the provided h(ash) parameter, the f(ile) parameter or just use HEAD.
  my $hash = ($h =~ /[^a-f0-9]/ ? $m->head_hash($h) : $h)
          || ($f && $m->hash_by_path($f))
          || $m->head_hash
          # XXX This could definitely use more context.
          || Carp::croak("Couldn't find a hash for the commit object!");

  my $obj = $m->get_object($hash)
    or Carp::croak("Couldn't find a object for '$hash' in '$pd'!");

  return $obj;
}

sub index : Chained('base') PathPart('') Args(0) {
  my ( $self, $c ) = @_;

  $c->detach($c->req->param('a'))
    if $c->req->param('a');

  my @list = @{ $c->model()->repositories };
  die 'No repositories found in '. $c->model->repo_dir
    unless @list;

  my $search = $c->req->param('s') || '';
  if($search) {
    @list = grep {
         index($_->name, $search) > -1
      or ( $_->description !~ /^Unnamed repository/ and index($_->description, $search) > -1 )
    } @list
  }

  $c->stash(
    search_text => $search,
    repositories    => \@list,
    action      => 'index',
  );
}

# FIXME - WTF is this for?
sub repository_index : Chained('base') Args(0) {
  my ( $self, $c ) = @_;

  my @list = @{ $c->model()->repositories };
  die 'No repositories found in '. $c->model->repo_dir
    unless @list;

  $c->response->content_type('text/plain');
  $c->response->body(
    join "\n", map $_->name, @list
  );
  $c->response->status(200);
}
# FIXME - maintain compatibility with previous URI
sub project_index : Chained('base') Args(0) {
    my ( $self, $c) = @_;
    $c->detach('repository_index');
}

=head2 summary

A summary of what's happening in the repo.

=cut

sub summary : Chained('base') Args(0) {
  my ( $self, $c ) = @_;
  my $repository = $c->stash->{Repository};
  $c->detach('error_404') unless $repository;
  my $commit = $self->_get_object($c);
  my @heads  = @{$repository->heads};
  my $maxitems = Gitalist->config->{paging}{summary} || 10;
  $c->stash(
    commit    => $commit,
    log_lines => [$repository->list_revs(
        sha1 => $commit->sha1,
        count => $maxitems,
    )],
    refs      => $repository->references,
    heads     => [ @heads[0 .. ($#heads < $maxitems ? $#heads : $maxitems)] ],
    action    => 'summary',
  );
}

=head2 heads

The current list of heads (aka branches) in the repo.

=cut

sub heads : Chained('base') Args(0) {
  my ( $self, $c ) = @_;
  my $repository = $c->stash->{Repository};
  $c->stash(
    commit => $self->_get_object($c),
    heads  => $repository->heads,
    action => 'heads',
  );
}

=head2 tags

The current list of tags in the repo.

=cut

sub tags : Chained('base') Args(0) {
  my ( $self, $c ) = @_;
  my $repository = $c->stash->{Repository};
  $c->stash(
    commit => $self->_get_object($c),
    tags   => $repository->tags,
    action => 'tags',
  );
}

sub blame : Chained('base') Args(0) {
  my($self, $c) = @_;

  my $repository = $c->stash->{Repository};
  my $h  = $c->req->param('h')
       || $repository->hash_by_path($c->req->param('hb'), $c->req->param('f'))
       || die "No file or sha1 provided.";
  my $hb = $c->req->param('hb')
       || $repository->head_hash
       || die "Couldn't discern the corresponding head.";
  my $filename = $c->req->param('f') || '';

  my $blame = $repository->get_object($hb)->blame($filename);
  $c->stash(
    blame    => $blame,
    head     => $repository->get_object($hb),
    filename => $filename,

    # XXX Hack hack hack, see View::SyntaxHighlight
    language => ($filename =~ /\.p[lm]$/i ? 'Perl' : ''),
    blob     => join("\n", map $_->{line}, @$blame),
  );

  $c->forward('View::SyntaxHighlight')
    unless $c->stash->{no_wrapper};
}

=head2 blob

The blob action i.e the contents of a file.

=cut

# blob can be identified by
# ?h = sha1 of a blob, OR
# ?f = file path, with optional
# ?hb = sha1 of a commit
sub blob : Chained('base') Args(0) {
    my ( $self, $c ) = @_;
    my $repo = $c->stash->{Repository};
    my $blob_sha1 = $c->req->param('h');
    my $blob_path = $c->req->param('f');
    my $commit = $repo->get_object(
        $c->req->param('hb') || $repo->head_hash
    );

    if (defined $blob_sha1) {
        $c->stash(
            blob     => $repo->get_object($blob_sha1)->content,
            filename => '',
        );
    } elsif (defined $blob_path) {
        $c->stash(
            blob     => $commit->get_blob_by_path($blob_path)->content,
            filename => $blob_path,
        );
    } else {
        die "No file or sha1 provided.";
    }

    $c->stash(
        head     => $commit,
        # XXX Hack hack hack, see View::SyntaxHighlight
        language => ($blob_path =~ /\.p[lm]$/i ? 'Perl' : ''),
        action   => 'blob',
    );

    $c->forward('View::SyntaxHighlight')
        unless $c->stash->{no_wrapper};
}

=head2 blob_plain

The plain text version of blob, where file is rendered as is.

=cut

sub blob_plain : Chained('base') Args(0) {
  my($self, $c) = @_;

  $c->stash->{no_wrapper} = 1;
  $c->forward($self->action_for('blob'));

  $c->response->content_type('text/plain; charset=utf-8');
  $c->response->body($c->stash-{blob});
  $c->response->status(200);
}

=head2 blobdiff_plain

The plain text version of blobdiff.

=cut

sub blobdiff_plain : Chained('base') Args(0) {
  my($self, $c) = @_;

  $c->stash(no_wrapper => 1);
  $c->response->content_type('text/plain; charset=utf-8');

  $c->forward('blobdiff');
}

=head2 blobdiff

Exposes a given diff of a blob.

=cut

sub blobdiff : Chained('base') Args(0) {
  my ( $self, $c ) = @_;
  my $commit = $self->_get_object($c, $c->req->param('hb'));
  my $filename = $c->req->param('f')
              || croak("No file specified!");
  my($tree, $patch) = $c->stash->{Repository}->diff(
    commit => $commit,
    patch  => 1,
    parent => $c->req->param('hpb') || undef,
    file   => $filename,
  );
  $c->stash(
    commit    => $commit,
    diff      => $patch,
    filename  => $filename,
    # XXX Hack hack hack, see View::SyntaxHighlight
    blobs     => [$patch->[0]->{diff}],
    language  => 'Diff',
    action    => 'blobdiff',
  );

  $c->forward('View::SyntaxHighlight')
    unless $c->stash->{no_wrapper};
}

=head2 commit

Exposes a given commit.

=cut

sub commit : Chained('base') Args(0) {
  my ( $self, $c ) = @_;
  my $repository = $c->stash->{Repository};
  my $commit = $self->_get_object($c);
  $c->stash(
      commit      => $commit,
      diff_tree   => ($repository->diff(commit => $commit))[0],
      refs      => $repository->references,
      action      => 'commit',
  );
}

=head2 commitdiff

Exposes a given diff of a commit.

=cut

sub commitdiff : Chained('base') Args(0) {
  my ( $self, $c ) = @_;
  my $commit = $self->_get_object($c);
  my($tree, $patch) = $c->stash->{Repository}->diff(
      commit => $commit,
      parent => $c->req->param('hp') || undef,
      patch  => 1,
  );
  $c->stash(
    commit    => $commit,
    diff_tree => $tree,
    diff      => $patch,
    # XXX Hack hack hack, see View::SyntaxHighlight
    blobs     => [map $_->{diff}, @$patch],
    language  => 'Diff',
    action    => 'commitdiff',
  );

  $c->forward('View::SyntaxHighlight')
    unless $c->stash->{no_wrapper};
}

sub commitdiff_plain : Chained('base') Args(0) {
  my($self, $c) = @_;

  $c->stash(no_wrapper => 1);
  $c->response->content_type('text/plain; charset=utf-8');

  $c->forward('commitdiff');
}

=head2 shortlog

Expose an abbreviated log of a given sha1.

=cut

sub shortlog : Chained('base') Args(0) {
  my ( $self, $c ) = @_;

  my $repository  = $c->stash->{Repository};
  my $commit   = $self->_get_object($c, $c->req->param('hb'));
  my $filename = $c->req->param('f') || '';

  my %logargs = (
      sha1   => $commit->sha1,
      count  => Gitalist->config->{paging}{log} || 25,
      ($filename ? (file => $filename) : ())
  );

  my $page = $c->req->param('pg') || 0;
  $logargs{skip} = $c->req->param('pg') * $logargs{count}
    if $c->req->param('pg');

  $c->stash(
      commit    => $commit,
      log_lines => [$repository->list_revs(%logargs)],
      refs      => $repository->references,
      page      => $page,
      filename  => $filename,
      action    => 'shortlog',
  );
}

=head2 log

Calls shortlog internally. Perhaps that should be reversed ...

=cut

sub log : Chained('base') Args(0) {
    $_[0]->shortlog($_[1]);
    $_[1]->stash->{action} = 'log';
}

# For legacy support.
sub history : Chained('base') Args(0) {
    my ( $self, $c ) = @_;
    $self->shortlog($c);
    my $repository = $c->stash->{Repository};
    my $file = $repository->get_object(
        $repository->hash_by_path(
            $repository->head_hash,
            $c->stash->{filename}
        )
    );
     $c->stash( action => 'history',
               filetype => $file->type,
           );
}

=head2 tree

The tree of a given commit.

=cut

sub tree : Chained('base') Args(0) {
  my ( $self, $c ) = @_;
  my $repository = $c->stash->{Repository};
  my $commit  = $self->_get_object($c, $c->req->param('hb'));
  my $filename = $c->req->param('f') || '';
  my $tree    = $filename
    ? $repository->get_object($repository->hash_by_path($commit->sha1, $filename))
    : $repository->get_object($commit->tree_sha1)
  ;
  $c->stash(
      commit    => $commit,
      tree      => $tree,
      tree_list => [$repository->list_tree($tree->sha1)],
      path      => $c->req->param('f') || '',
      action    => 'tree',
  );
}

=head2 reflog

Expose the local reflog. This may go away.

=cut

sub reflog : Chained('base') Args(0) {
  my ( $self, $c ) = @_;
  my @log = $c->stash->{Repository}->reflog(
      '--since=yesterday'
  );

  $c->stash(
      log    => \@log,
      action => 'reflog',
  );
}

=head2 search

The action for the search form.

=cut

sub search : Chained('base') Args(0) {
  my($self, $c) = @_;
  $c->stash(current_action => 'GitRepos');
  my $repository = $c->stash->{Repository};
  my $commit  = $self->_get_object($c);
  # Lifted from /shortlog.
  my %logargs = (
    sha1   => $commit->sha1,
    count  => Gitalist->config->{paging}{log},
    ($c->req->param('f') ? (file => $c->req->param('f')) : ()),
    search => {
      type   => $c->req->param('type'),
      text   => $c->req->param('text'),
      regexp => $c->req->param('regexp') || 0,
    },
  );

  $c->stash(
      commit  => $commit,
      results => [$repository->list_revs(%logargs)],
      action  => 'search',
	  # This could be added - page      => $page,
  );
}

=head2 search_help

Provides some help for the search form.

=cut

sub search_help : Chained('base') Args(0) {
    my ($self, $c) = @_;
    $c->stash(template => 'search_help.tt2');
}

=head2 atom

Provides an atom feed for a given repository.

=cut

sub atom : Chained('base') Args(0) {
  my($self, $c) = @_;

  my $feed = XML::Atom::Feed->new;

  my $host = lc Sys::Hostname::hostname();
  $feed->title($host . ' - ' . Gitalist->config->{name});
  $feed->updated(~~DateTime->now);

  my $repository = $c->stash->{Repository};
  my %logargs = (
      sha1   => $repository->head_hash,
      count  => Gitalist->config->{paging}{log} || 25,
      ($c->req->param('f') ? (file => $c->req->param('f')) : ())
  );

  my $mk_title = $c->stash->{short_cmt};
  for my $commit ($repository->list_revs(%logargs)) {
    my $entry = XML::Atom::Entry->new;
    $entry->title( $mk_title->($commit->comment) );
    $entry->id($c->uri_for('commit', {h=>$commit->sha1}));
    # XXX Needs work ...
    $entry->content($commit->comment);
    $feed->add_entry($entry);
  }

  $c->response->body($feed->as_xml);
  $c->response->content_type('application/atom+xml');
  $c->response->status(200);
}

=head2 rss

Provides an RSS feed for a given repository.

=cut

sub rss : Chained('base') Args(0) {
  my ($self, $c) = @_;

  my $repository = $c->stash->{Repository};

  my $rss = XML::RSS->new(version => '2.0');
  $rss->channel(
    title          => lc(Sys::Hostname::hostname()) . ' - ' . Gitalist->config->{name},
    link           => $c->uri_for('summary', {p=>$repository->name}),
    language       => 'en',
    description    => $repository->description,
    pubDate        => DateTime->now,
    lastBuildDate  => DateTime->now,
  );

  my %logargs = (
      sha1   => $repository->head_hash,
      count  => Gitalist->config->{paging}{log} || 25,
      ($c->req->param('f') ? (file => $c->req->param('f')) : ())
  );
  my $mk_title = $c->stash->{short_cmt};
  for my $commit ($repository->list_revs(%logargs)) {
    # XXX Needs work ....
    $rss->add_item(
        title       => $mk_title->($commit->comment),
        permaLink   => $c->uri_for(commit => {h=>$commit->sha1}),
        description => $commit->comment,
    );
  }

  $c->response->body($rss->as_string);
  $c->response->content_type('application/rss+xml');
  $c->response->status(200);
}

sub opml : Chained('base') Args(0) {
  my($self, $c) = @_;

  my $opml = XML::OPML::SimpleGen->new();

  $opml->head(title => lc(Sys::Hostname::hostname()) . ' - ' . Gitalist->config->{name});

  my @list = @{ $c->model()->repositories };
  die 'No repositories found in '. $c->model->repo_dir
    unless @list;

  for my $proj ( @list ) {
    $opml->insert_outline(
      text   => $proj->name. ' - '. $proj->description,
      xmlUrl => $c->uri_for(rss => {p => $proj->name}),
    );
  }

  $c->response->body($opml->as_string);
  $c->response->content_type('application/rss');
  $c->response->status(200);
}

=head2 patch

A raw patch for a given commit.

=cut

sub patch : Chained('base') Args(0) {
    my ($self, $c) = @_;
    $c->detach('patches', [1]);
}

=head2 patches

The patcheset for a given commit ???

=cut

sub patches : Chained('base') Args(0) {
    my ($self, $c, $count) = @_;
    $count ||= Gitalist->config->{patches}{max};
    my $commit = $self->_get_object($c);
    my $parent = $c->req->param('hp') || undef;
    my $patch = $commit->get_patch( $parent, $count );
    $c->response->body($patch);
    $c->response->content_type('text/plain');
    $c->response->status(200);
}

=head2 snapshot

Provides a snapshot of a given commit.

=cut

sub snapshot : Chained('base') Args(0) {
    my ($self, $c) = @_;
    my $format = $c->req->param('sf') || 'tgz';
    die unless $format;
    my $sha1 = $c->req->param('h') || $self->_get_object($c)->sha1;
    my @snap = $c->stash->{Repository}->snapshot(
        sha1 => $sha1,
        format => $format
    );
    $c->response->status(200);
    $c->response->headers->header( 'Content-Disposition' =>
                                       "attachment; filename=$snap[0]");
    $c->response->body($snap[1]);
}


sub base : Chained('/root') PathPart('') CaptureArgs(0) {
  my($self, $c) = @_;

  my $repository = $c->req->param('p');
  if (defined $repository) {
    eval {
      $c->stash(Repository => $c->model('GitRepos')->get_repository($repository));
    };
    if ($@) {
      $c->detach('/error_404');
    }
  }

  my $a_repository = $c->stash->{Repository} || $c->model()->repositories->[0];
  $c->stash(
    git_version => $a_repository->run_cmd('--version'),
    version     => $Gitalist::VERSION,

    # XXX Move these to a plugin!
    time_since => sub {
      return 'never' unless $_[0];
      return age_string(time - $_[0]->epoch);
    },
    short_cmt => sub {
      my $cmt = shift;
      my($line) = split /\n/, $cmt;
      $line =~ s/^(.{70,80}\b).*/$1 \x{2026}/;
      return $line;
    },
    abridged_description => sub {
        join(' ', grep { defined } (split / /, shift)[0..10]);
    },
  );
}

sub end : ActionClass('RenderView') {
    my ($self, $c) = @_;
    # Give repository views the current HEAD.
    if ($c->stash->{Repository}) {
        $c->stash->{HEAD} = $c->stash->{Repository}->head_hash;
    }
}

sub error_404 : Action {
    my ($self, $c) = @_;
    $c->response->status(404);
    $c->response->body('Page not found');
}

__PACKAGE__->meta->make_immutable;

__END__

=head1 NAME

Gitalist::Controller::Root - Root controller for the application

=head1 DESCRIPTION

This controller handles all of the root level paths for the application

=head1 METHODS

=head2 root

Root of chained actions

=head2 base

Populate the header and footer. Perhaps not the best location.

=head2 index

Provides the repository listing.

=head2 end

Attempt to render a view, if needed.

=head2 blame

=head2 commitdiff_plain

=head2 error_404

=head2 history

=head2 opml

=head2 repository_index

=head1 AUTHORS

See L<Gitalist> for authors.

=head1 LICENSE

See L<Gitalist> for the license.

=cut
