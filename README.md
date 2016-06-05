# NAME

Net::Google::Drive::Extended - Used to modify Google Drive data using service account (server-to-server)

# SYNOPSIS

    use Net::Google::Drive::Extended;

    my $gd = Net::Google::Drive::Extended->new( 
        secret_json => 'YourProject.json',

         # Pass this param if you want to read files from 
         # your account space instead of service account space
        login_email => 'name@domain.com' #(optional)
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

# DESCRIPTION

Net::Google::Drive::Extended authenticates with a Google Drive service account (server-to-server) and offers several convenience methods to list, retrieve, and modify the data stored in the google drive. 

Refer: https://developers.google.com/identity/protocols/OAuth2ServiceAccount for creating a service account and the client\_secret json file.

Refer: https://developers.google.com/drive/v3/reference/ for list of file properties, response values, query\_params and body\_params.

# METHODS

- **new**

        my $gd = Net::Google::Drive::Extended->new(
                secret_json => "./YourProject.json"
            );

    Parameters can be

        login_email (optional)
            - email id of the account, if set, then all operations will be done in that respective user's space.

        http_retry_no (default 0)
            - number of time each http requests should be retried if the request is failed

        http_retry_interval (default 5)
            - time interval in seconds after with the another attempt will be made for the previously failed http request, this setting is useless when http_retry_no is set to 0

        show_trashed (default 0)
            - when this value is set, trash files filter will be disabled

- **files**

    Params  : $query\_params (optional), $body\_params(optional)

    Returns : List of files

    Desc    : Get all files from your drive

    Usage   :

        my $files_at_drive = $gd->files();

- **children**

    Params  : $path, $query\_params (optional), $body\_params (optional)

    Returns : All items under the given path as an array ref

    Desc    : Get children of given directory. Since the directory path is iteratively found for optimization $parent\_id is returned as second argument when calling in array context.

    Usage   :

        my $children = $gd->children('/my_docs' [,$query_params, $body_params]);

        or 

        my ($children, $parent_id) = $gd->children('/my_docs' [,$query_params, $body_params]);

- **children\_by\_folder\_id**

    Params  : $folder\_id, $query\_params (optional), $body\_params (optional)

    Returns : Arrayref of items (files)

    Desc    : Get all the items which has $folder\_id as parent, with default query\_param value maxResults as 100

    Usage   : 

        my $items = $gd->children_by_folder_id($parent_id, { maxResults => 1000 });

- **new\_file**

    Params  : $local\_file\_path, $folder\_id, $description (optional)

    Returns : new file id, ( and second argument as response data hashref when called in array context )

    Desc    : Uploads a new file ( file at $local\_file\_path ) to the drive in the give folder ( given folder\_id )

    Usage   : 

        my $file_id = $gd->new_file('./testfile', $parent_id, "This is a test file upload");

- **update\_file**

    Params  : $old\_file\_id, $updated\_local\_file\_path

    Returns : $file\_id on Successful upload

    Desc    : This will replace the existing file in the drive with new file.

    Usage   : 

        my $file_id = $gd->update_file($old_file_id, "./updated_file");

- **delete**

    Params  : $item\_id (It can be a file\_id or folder\_id)

    Returns : deleted file id on successful deletion

    Desc    : Deletes an item from google drive.

    Usage   :

        my $deleted_file_id = $gd->delete($file_id);

- **create\_folder**

    Params  : $folder\_name, $parent\_folder\_id

    Returns : $folder\_id (newly created folder Id)
        If called in an array context then second argument will be the http response data

    Desc    : Used to create a new directory in you drive

    Usage   : 

        my $new_folder_id = $gd->create_folder("Test",$parent_id);

- **search**

    Params  : $query string, $query\_params (optional), $body\_params (optional)

    Returns : Result items (files) for the given query

    Desc    : Do search on the google drive using the syntax mentioned in google drive, refer https://developers.google.com/drive/v3/web/search-parameters for list of search parameters and examples

    Usage   :

        my $items = $gd->search("mimeType contains 'image/'",{ maxResults => 10 });

- **download**

    Params  : $file\_url, $local\_file\_path

    Returns : 0/1 when $file\_path is given, or returns the file content

    Desc    : Download file from the drive, when you pass url as a ref this mehtod will try to find the $url->{downloadUrl} and tries to download that file. When local file name with path is not given, this method will return the content of the file on success download.

    Usage   :

        $gd->download($url, $local_file);

        or

        my $file_content = $gd->download($url);

- **file\_mime\_type**

    Params  : $local\_file\_path

    Returns : mime type of the given file

    Desc    : Find the MimeType of a file using File::Type

    Usage   : 

        my $mime_type = $gd->file_mime_type("./testfile");

- **remove\_trashed**

    Params  : $items\_arrayref ( return value of files() or children() )

    Returns : $items arrayref

    Desc    : This method will filter out all the files marked as trashed

    Usage   :

        my $items = $gd->children('./MyDocs');

        # do something with the data

        my $live_items = $gd->remove_trashed($items);

- **show\_trash\_data**

    Params  : 0/1

    Returns : NONE

    Desc    : Disable/Enable listing deleted data from your drive

    Usage   :
        $gd->show\_trash\_data(1);
        my $all\_files = $gd->children('/'); # will return all the files including files in trash

# Error handling

In case of an error while retrieving information from the Google Drive
API, the methods above will return `undef` and a more detailed error
message can be obtained by calling the `error()` method:

    print "An error occurred: ", $gd->error();
       

# LOGGING/DEBUGGING

Net::Google::Drive::Extended is Log4perl-enabled.
To find out what's going on under the hood, turn on Log4perl:

    use Log::Log4perl qw(:easy);
    Log::Log4perl->easy_init($DEBUG);
           

# SEE ALSO

Net::Google::Drive::Simple

# LICENSE

Copyright 2016 by Dinesh Dharmalingam, all rights reserved. This program is free software, you can redistribute it and/or modify it under the same terms as Perl itself.

# AUTHORS

Dinesh D, <dinesh@exceleron.com>
