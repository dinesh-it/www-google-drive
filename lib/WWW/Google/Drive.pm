# ========================================================================== #
# WWW::Google::Drive
#            - Used to modify Google Drive data using service account (server to server) operations
# ========================================================================== #

package WWW::Google::Drive;

use Moose;
use Log::Log4perl qw(:easy);

use URI;
use HTTP::Request;
use HTTP::Headers;
use HTTP::Request::Common;
use HTML::Entities;
use LWP::UserAgent;

use JSON qw( from_json to_json decode_json);
use JSON::WebToken;
use Config::JSON;

use Sysadm::Install qw( slurp );
use File::Basename;
use File::Type;

our $VERSION = "0.01";

=head1 NAME

WWW::Google::Drive - Used to modify Google Drive data using service account (server-to-server)

=head1 SYNOPSIS

    use WWW::Google::Drive;

    my $gd = WWW::Google::Drive->new( 
        secret_json => 'YourProject.json',

         # Set the Google user to impersonate. 
         # Your Google Business Administrator must have already set up 
         # your Client ID as a trusted app in order to use this successfully.
        user_as => 'name@domain.com' #(optional)
    );
    my $children = $gd->children('/MyDocs');

    foreach my $item (@{$children}){
        if($item->{downloadUrl}){
        print "Found file $item->{title} and it " . 
            "can be downloaded at $item->{downloadUrl}\n";
        }
        else{
            print "File $item->{title} can not downloaded, please use export\n";
        }
    }

=head1 DESCRIPTION

WWW::Google::Drive authenticates with a Google Drive service account (server-to-server) and offers several convenience methods to list, retrieve, and modify the data stored in the google drive. 

Refer: https://developers.google.com/identity/protocols/OAuth2ServiceAccount for creating a service account and the client_secret json file.

Refer: https://developers.google.com/drive/v3/reference/ for list of file properties, response values, query_params and body_params.

=head1 METHODS

=over 4

=cut

has secret_json         => (is => "ro");
has user_as             => (is => 'ro');
has init_done           => (is => "rw");
has http_retry_no       => (is => "ro", default => 0);
has http_retry_interval => (is => "ro", default => 5);
has show_trashed        => (is => 'rw', default => 0);
has scope               => (is => "rw", default => 'https://www.googleapis.com/auth/drive');
has token_uri           => (is => "ro", default => 'https://www.googleapis.com/oauth2/v4/token');
has api_file_url        => (is => "ro", default => 'https://www.googleapis.com/drive/v2/files');
has api_upload_url      => (is => "ro", default => 'https://www.googleapis.com/upload/drive/v2/files');

has error => (
    is      => "rw",
    trigger => sub {
        my ($self, $set) = @_;
        if (defined $set) {
            $self->{error} = $set;
        }
        return $self->{error};
    }
);

=item B<new>

    my $gd = WWW::Google::Drive->new(
            secret_json => "./YourProject.json"
        );

Parameters can be
    
    user_as (optional)
        - email id of the account, if set, then all operations will be done in that respective user's space.

    http_retry_no (default 0)
        - number of time each http requests should be retried if the request is failed

    http_retry_interval (default 5)
        - time interval in seconds after with the another attempt will be made for the previously failed http request, this setting is useless when http_retry_no is set to 0

    show_trashed (default 0)
        - when this value is set, trash files filter will be disabled

=cut

# ============================================= BUILD ======================================== #

sub BUILD
{
    my $self = shift;

    $self->{file_type_obj} = File::Type->new();
}

# ========================================= files ============================================= #

=item B<files>

Params  : $query_params (optional), $body_params(optional)

Returns : List of files

Desc    : Get all files from your drive

Usage   :
    
    my $files_at_drive = $gd->files();

=cut

sub files
{
    my ($self, $query_params, $body_params) = @_;

    if (!defined $body_params) {
        $body_params = {};
    }
    $body_params = {
        page => 1,
        %$body_params,
    };

    if (!defined $query_params) {
        $query_params = {};
    }

    my @docs = ();

    my $more_pages = 1;

    while ($more_pages) {

        $more_pages = 0;

        my $url  = $self->_file_uri($query_params);
        my $data = $self->_get_http_json_response($url);

        return undef unless ($data);

        my $items = $data->{items};

        if (!$self->show_trashed) {
            $items = $self->remove_trashed($items);
        }

        foreach my $item (@{$items}) {
            if ($item->{kind} eq "drive#file") {
                my $file = $item->{originalFilename};
                if (!defined $file) {
                    DEBUG "Skipping $item->{title} (no originalFilename)";
                    next;
                }

                push @docs, $item;
            }
            else {
                DEBUG "Skipping $item->{title} ($item->{kind})";
            }
        }

        if ($body_params->{page} and $data->{nextPageToken}) {
            $query_params->{pageToken} = $data->{nextPageToken};
            $more_pages = 1;
        }
    }

    return \@docs;
}

# ========================================= children ========================================= #

=item B<children>

Params  : $path, $query_params (optional), $body_params (optional)

Returns : All items under the given path as an array ref

Desc    : Get children of given directory. Since the directory path is iteratively found for optimization $parent_id is returned as second argument when calling in array context.

Usage   :

    my $children = $gd->children('/my_docs' [,$query_params, $body_params]);

    or 

    my ($children, $parent_id) = $gd->children('/my_docs' [,$query_params, $body_params]);

=cut

sub children
{
    my ($self, $path, $query_params, $body_params) = @_;

    if (!defined $path) {
        LOGDIE "No path given";
    }

    DEBUG "Determine children of $path";

    my ($folder_id, $parent) = $self->_path_to_folderid($path, $query_params, $body_params);

    unless ($folder_id) {
        DEBUG "Unable to resolve path $path";
        return undef;
    }

    return undef unless ($folder_id);

    DEBUG "Getting content of folder $folder_id, Path: $path";

    my $children = $self->children_by_folder_id($folder_id, $body_params);

    if (!defined $children) {
        return undef;
    }

    if (wantarray) {
        return ($children, $parent);
    }
    else {
        return $children;
    }
}

# =================================== children_by_folder_id ===================================== #

=item B<children_by_folder_id>

Params  : $folder_id, $query_params (optional), $body_params (optional)

Returns : Arrayref of items (files)

Desc    : Get all the items which has $folder_id as parent, with default query_param value maxResults as 100

Usage   : 
    
    my $items = $gd->children_by_folder_id($parent_id, { maxResults => 1000 });

=cut

sub children_by_folder_id
{
    my ($self, $folder_id, $query_params, $body_params) = @_;

    if (!defined $body_params) {
        $body_params = {};
    }

    $body_params = {
        page => 1,
        %$body_params,
    };

    if (!defined $query_params) {
        $query_params = {maxResults => 100,};
    }

    my $url = URI->new($self->{api_file_url});
    $query_params->{q} = "'$folder_id' in parents";

    if ($body_params->{title}) {
        $query_params->{q} .= " AND title = '$body_params->{ title }'";
    }

    my $result = $self->_get_items_from_result($url, $query_params, $body_params);

    return $result;
}

# ====================================== new_file =========================================== #

=item B<new_file>

Params  : $local_file_path, $folder_id, $options (optional key value pairs)

Returns : new file id, ( and second argument as response data hashref when called in array context )

Desc    : Uploads a new file ( file at $local_file_path ) to the drive in the give folder ( given folder_id )

Usage   : 

    my $file_id = $gd->new_file('./testfile', $parent_id, { description => "This is a test file upload" });

=cut

sub new_file
{
    my ($self, $file, $parent_id, $options) = @_;

    my $title = basename $file;

    # First, POST the new file metadata to the Drive endpoint
    # http://stackoverflow.com/questions/10317638/inserting-file-to-google-drive-through-api
    my $url       = URI->new($self->{api_file_url});
    my $mime_type = $self->file_mime_type($file);

    my $data = $self->_get_http_json_response(
        $url,
        {
            mimeType    => $mime_type,
            parents     => [{id => $parent_id}],
            title       => $title,
            %{$options}
        }
    );

    return undef unless ($data);

    my $file_id = $data->{id};

    $file_id = $self->_file_upload($file_id, $file, $mime_type);

    if (wantarray) {
        return ($file_id, $data);
    }
    else {
        return $file_id;
    }
}

# ===================================== update_file ========================================= #

=item B<update_file>

Params  : $old_file_id, $updated_local_file_path

Returns : $file_id on Successful upload

Desc    : This will replace the existing file in the drive with new file.

Usage   : 

    my $file_id = $gd->update_file($old_file_id, "./updated_file");

=cut

sub update_file
{
    my ($self, $file_id, $file_path) = @_;

    return $self->_file_upload($file_id, $file_path);
}

# ====================================== delete ======================================== #

=item B<delete>

Params  : $item_id (It can be a file_id or folder_id)

Returns : deleted file id on successful deletion

Desc    : Deletes an item from google drive.

Usage   :
    
    my $deleted_file_id = $gd->delete($file_id);

=cut

sub delete
{
    my ($self, $item_id) = @_;

    LOGDIE 'Deletion requires file_id' if (!defined $item_id);

    my $url = URI->new($self->{api_file_url} . "/$item_id");

    my $req = &HTTP::Request::Common::DELETE($url->as_string, $self->_authorization_headers(),);

    my $resp = $self->_http_rsp_data($req);

    DEBUG $resp->as_string;

    if ($resp->is_error) {
        $self->error($resp->message());
        return undef;
    }

    return $item_id;
}

# ===================================== create_folder ======================================== #

=item B<create_folder>

Params  : $folder_name, $parent_folder_id

Returns : $folder_id (newly created folder Id)
    If called in an array context then second argument will be the http response data

Desc    : Used to create a new directory in you drive

Usage   : 
    
    my $new_folder_id = $gd->create_folder("Test",$parent_id);

=cut

sub create_folder
{
    my ($self, $title, $parent) = @_;

    LOGDIE "create_folder need 2 arguments (title and parent_id)" unless ($title or $parent);

    my $url = URI->new($self->{api_file_url});

    my $data = $self->_get_http_json_response(
        $url,
        {
            title    => $title,
            parents  => [{id => $parent}],
            mimeType => "application/vnd.google-apps.folder",
        }
    );

    if (!defined $data) {
        return undef;
    }

    if (wantarray) {
        return ($data->{id}, $data);
    }
    else {
        return $data->{id};
    }
}

# ========================================= search ========================================= #

=item B<search>

Params  : $query string, $query_params (optional), $body_params (optional)

Returns : Result items (files) for the given query

Desc    : Do search on the google drive using the syntax mentioned in google drive, refer https://developers.google.com/drive/v3/web/search-parameters for list of search parameters and examples

Usage   :

    my $items = $gd->search("mimeType contains 'image/'",{ maxResults => 10 });

=cut

sub search
{
    my ($self, $query, $query_params, $body_params) = @_;
    $body_params ||= {page => 1};

    if (!defined $query_params) {
        $query_params = {maxResults => 100,};
    }

    my $url = URI->new($self->{api_file_url});

    $query_params->{q} = $query;

    my $items = $self->_get_items_from_result($url, $query_params, $body_params);

    return $items;
}

# ========================================= download ========================================= #

=item B<download>

Params  : $file_url, $local_file_path

Returns : 0/1 when $file_path is given, or returns the file content

Desc    : Download file from the drive, when you pass url as a ref this mehtod will try to find the $url->{downloadUrl} and tries to download that file. When local file name with path is not given, this method will return the content of the file on success download.

Usage   :

    $gd->download($url, $local_file);

    or

    my $file_content = $gd->download($url);

=cut

sub download
{
    my ($self, $url, $local_file) = @_;

    if (ref $url) {
        $url = $url->{downloadUrl};
    }

    if (not $url) {
        my $msg = "Can't download, download url not found";
        ERROR $msg;
        $self->error($msg);
        return undef;
    }

    my $req = HTTP::Request->new(GET => $url,);
    $req->header($self->_authorization_headers());

    my $ua = LWP::UserAgent->new();
    my $resp = $ua->request($req, $local_file);

    if ($resp->is_error()) {
        my $msg = "Can't download $url (" . $resp->message() . ")";
        ERROR $msg;
        $self->error($msg);
        return undef;
    }

    if ($local_file) {
        return 1;
    }

    return $resp->content();
}

# ====================================== file_mime_type ====================================== #

=item B<file_mime_type>

Params  : $local_file_path

Returns : mime type of the given file

Desc    : Find the MimeType of a file using File::Type

Usage   : 
    
    my $mime_type = $gd->file_mime_type("./testfile");

=cut

sub file_mime_type
{
    my ($self, $file) = @_;

    return $self->{file_type_obj}->checktype_filename($file);
}

# ====================================== remove_trashed ====================================== #

=item B<remove_trashed>

Params  : $items_arrayref ( return value of files() or children() )

Returns : $items arrayref

Desc    : This method will filter out all the files marked as trashed

Usage   :

    my $items = $gd->children('./MyDocs');

    # do something with the data

    my $live_items = $gd->remove_trashed($items);

=cut

sub remove_trashed
{
    my ($self, $data) = @_;

    return unless (defined $data);

    if (ref $data ne 'ARRAY') {
        LOGDIE "remove_trashed expects an array ref argument, but called with " . ref $data;
    }

    my @new_data = ();

    foreach my $item (@{$data}) {
        if ($item->{labels}->{trashed}) {
            DEBUG "Skipping trashed item '$item->{title}'";
            next;
        }
        push(@new_data, $item);
    }

    return \@new_data;
}

# ====================================== show_trash_data ===================================== #

=item B<show_trash_data>

Params  : 0/1

Returns : NONE

Desc    : Disable/Enable listing deleted data from your drive

Usage   :
    $gd->show_trash_data(1);
    my $all_files = $gd->children('/'); # will return all the files including files in trash

=cut

sub show_trash_data
{
    my $self    = shift;
    my $boolean = shift;
    $self->{show_trashed} = $boolean;
}

# ====================================== _file_upload ======================================== #

sub _file_upload
{
    my ($self, $file_id, $file, $mime_type) = @_;

    # Since a file upload can take a long time, refresh the token
    # just in case.
    $self->_token_expire();

    unless (-f $file) {
        LOGDIE "$file does not exist in your local machine";
        return undef;
    }

    my $file_data = slurp $file;
    $mime_type = $self->file_mime_type($file) unless ($mime_type);

    my $url = URI->new($self->{api_upload_url} . "/$file_id");
    $url->query_form(uploadType => "media");

    my $req = &HTTP::Request::Common::PUT(
        $url->as_string,
        $self->_authorization_headers(),
        "Content-Type" => $mime_type,
        "Content"      => $file_data,
    );

    my $resp = $self->_http_rsp_data($req);

    if ($resp->is_error()) {
        $self->error($resp->message());
        return undef;
    }

    DEBUG $resp->as_string;

    return $file_id;
}

# =================================== _get_items_from_result ============================== #

sub _get_items_from_result
{
    my ($self, $url, $query_params, $body_params) = @_;

    my @items;

    my $more_pages = 0;

    do {
        $url->query_form($query_params);

        my $data = $self->_get_http_json_response($url);

        return undef if (!defined $data);

        my $page_items = $data->{items};

        if (!$self->show_trashed) {
            $page_items = $self->remove_trashed($page_items);
        }

        push(@items, @{$page_items});

        $more_pages = 0;

        if ($body_params->{page} and $data->{nextPageToken}) {
            $query_params->{pageToken} = $data->{nextPageToken};
            $more_pages = 1;
        }
    } while ($more_pages);

    return \@items;
}

# =================================== _path_to_folderid ==================================== #

sub _path_to_folderid
{
    my ($self, $path, $body_params) = @_;

    my @parts = split '/', $path;

    if (!defined $body_params) {
        $body_params = {};
    }

    my $parent = $parts[0] = "root";

    DEBUG "Parent: $parent";

    my $folder_id = shift @parts;

  PART: for my $part (@parts) {

        DEBUG "Looking up part $part (folder_id=$folder_id)";

        my $children = $self->children_by_folder_id(
            $folder_id,
            {
                maxResults => 100,    # path resolution maxResults is different
            },
            {%$body_params, title => $part},
        );

        if (!defined $children) {
            DEBUG "Part $part not found in path $path";
            return undef;
        }

        for my $child (@$children) {
            DEBUG "Found child ", $child->{title};
            if ($child->{title} eq $part) {
                $folder_id = $child->{id};
                $parent    = $folder_id;
                DEBUG "Parent: $parent";
                next PART;
            }
        }

        my $msg = "Child $part not found";
        $self->error($msg);
        ERROR $msg;
        return undef;
    }

    return ($folder_id, $parent);
}

# =================================== _get_http_json_response ============================= #

sub _get_http_json_response
{
    my ($self, $url, $post_data) = @_;

    my $req = $self->_http_req_data($url, $post_data);

    my $resp = $self->_http_rsp_data($req);

    if ($resp->is_error()) {
        $self->error($resp->message());
        return undef;
    }

    my $json_data = from_json($resp->decoded_content());

    return $json_data;
}

# ======================================== _http_req_data ================================= #

sub _http_req_data
{
    my ($self, $url, $post_data) = @_;

    my $req;

    if ($post_data) {
        $req = &HTTP::Request::Common::POST(
            $url->as_string,
            $self->_authorization_headers(),
            "Content-Type" => "application/json",
            Content        => to_json($post_data),
        );
    }
    else {
        $req = HTTP::Request->new(GET => $url->as_string,);
        $req->header($self->_authorization_headers());
    }

    return $req;
}

# ====================================== _http_rsp_data ==================================== #

sub _http_rsp_data
{
    my ($self, $req, $noinit) = @_;

    my $ua = LWP::UserAgent->new();
    my $resp;

    my $RETRIES        = $self->http_retry_no;
    my $SLEEP_INTERVAL = $self->http_retry_interval;
    my $retry_count    = 0;

    {
        DEBUG "Fetching ", $req->url->as_string();

        $resp = $ua->request($req);

        if (!$resp->is_success()) {
            $self->error($resp->message());
            ERROR "Failed with ", $resp->code(), ": ", $resp->message();
            if (--$RETRIES >= 0) {
                ERROR "Retry (" . ++$retry_count . ") in $SLEEP_INTERVAL seconds";
                sleep $SLEEP_INTERVAL;
                redo;
            }
            else {
                return $resp;
            }
        }

        DEBUG "Successfully fetched ", length($resp->content()), " bytes.";
    }

    return $resp;
}

# ================================= _file_uri ==================================== #

sub _file_uri
{
    my ($self, $query_params) = @_;

    $query_params = {} if !defined $query_params;

    my $default_opts = {maxResults => 3000,};

    $query_params = {%$default_opts, %$query_params,};

    my $url = URI->new($self->{api_file_url});
    $url->query_form($query_params);

    return $url;
}

# =========================================== OAuth ========================================= #

# =================================== _authorization_headers ================================ #

sub _authorization_headers
{
    my ($self) = @_;

    return ('Authorization' => 'Bearer ' . $self->_get_oauth_token);
}

# ====================================== _get_oauth_token =================================== #

sub _get_oauth_token
{
    my ($self) = @_;

    if (not exists $self->{oauth}) {
        $self->_authenticate or LOGDIE "Google drive authentication failed";
        return $self->{oauth}->{_access_token};
    }

    my $time_remaining = $self->{oauth}->{_expires} - time();

    # checking if the token is still valid for more than 5 minutes
    # why 5 minutes? simply :-).
    if ($time_remaining < 300) {
        $self->_authenticate() or LOGDIE "Google drive token refresh failed";
    }

    return $self->{oauth}->{_access_token};
}

# ========================================== _authenticate =================================== #

sub _authenticate
{
    my ($self) = @_;

    LOGDIE "Config JSON file " . $self->secret_json . " not exist!" unless (-f $self->secret_json);

    my $config = Config::JSON->new($self->secret_json);

    my $time = time;

    my $service_acc_id     = $config->get("client_email");
    my $private_key_string = $config->get("private_key");

    my $jwt = JSON::WebToken->encode(
        {
            iss   => $service_acc_id,
            scope => $self->scope,
            aud   => $self->token_uri,
            exp   => $time + 3600,
            iat   => $time,

            # Access files from this users drive/ impersonate user
            prn => $self->user_as,
        },
        $private_key_string,
        'RS256',
        {typ => 'JWT'}
    );

    # Authenticate via post, and get a token
    my $ua       = LWP::UserAgent->new();
    my $response = $ua->post(
        $self->token_uri,
        {
            grant_type => encode_entities('urn:ietf:params:oauth:grant-type:jwt-bearer'),
            assertion  => $jwt
        }
    );

    unless ($response->is_success()) {
        LOGDIE $response->code, $response->content;
    }

    my $data = decode_json($response->content);

    $self->{oauth}->{_access_token} = $data->{access_token};

    # expires_in is number of seconds the token is valid, storing the validity epoch
    $self->{oauth}->{_expires} = $data->{expires_in} + time;
    return 1;
}

# ========================================== _token_expire ==================================== #

sub _token_expire
{
    my ($self) = @_;
    $self->{oauth}->{_expires} = time - 1;
}

1;

__END__

=back

=head1 Error handling
 
In case of an error while retrieving information from the Google Drive
API, the methods above will return C<undef> and a more detailed error
message can be obtained by calling the C<error()> method:
  
    print "An error occurred: ", $gd->error();
       
=head1 LOGGING/DEBUGGING
 
WWW::Google::Drive is Log4perl-enabled.
To find out what's going on under the hood, turn on Log4perl:
  
    use Log::Log4perl qw(:easy);
    Log::Log4perl->easy_init($DEBUG);

=head1 REPOSITORY

L<https://github.com/dinesh-it/www-google-drive>
           
=head1 SEE ALSO

Net::Google::Drive::Simple
Net::GoogleDrive

=head1 LICENSE

Copyright 2016 by Dinesh Dharmalingam, all rights reserved. This program is free software, you can redistribute it and/or modify it under the same terms as Perl itself.

=head1 AUTHORS

Dinesh D, <dinesh@exceleron.com>

=cut

