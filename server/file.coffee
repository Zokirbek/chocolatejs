# **File** is a system module which offers services on Chocolate system files
# 
# It provides :
#
# 1. a web editor interface to allow online source editing
# 2. web services to create and move source files
# 3. web services to interact with Git repository

Events = require 'events'
Fs = require 'fs'
Path = require 'path'
Util = require 'util'
# It uses **Git** to manage its system files versions
Git = require './git'

#### Public UI services

#### Access

# `access` service receives `where`, a system file path, and returns a web interface to edit the file.
exports.access = (where, backdoor_key, __) ->

    # `backdoor_key` is a security key that gives access to all system services. If provided it is sent back in the editor.

    # This service is asynchronous, 
    # so it returns an EventEmitter to which it will send an `end` message when it will be ready to send the web editor back.
    event = new Events.EventEmitter

    {where, path, error} = resolve where, __
    if error? then process.nextTick(-> with_error event, error) ; return event
    
    # First, get source file last modification date to pass it to the editor
    exports.getModifiedDate(path).on 'end', (modifiedDate) ->
        # Read the source file
        Fs.readFile path, (err, data) ->
            # Retrieve the commit list associated to this file from the Git repository 
            exports.getAvailableCommits(where, __).on 'end', (commits_list) ->
                # Build commit Options list
                commits = ''
                for commit in commits_list
                    commits += (if commits is '' then """<option value="">Current working item - Last commit on : #{commit.date} </option>""" else '') + '<option value="' + commit.sha + '">' + commit.date + ' - ' + commit.message + '</option>'
                commits = '<option value="">Current - Working item - Not commited' unless commits isnt ''

                # And finally, parse the source and render it with our web editor interface with the help of the excellent Coffeekup.
                # Send back the HTML.
                source = data.toString().replace(/\&/g, '&amp;').replace(/\</g, '&lt;').replace(/\>/g, '&gt;')
                html = require('../general/coffeekup').render clientInterface, locals: {source, commits, where, backdoor_key, modifiedDate}
                event.emit 'end', html
    event

#### Public File services

#### hasWriteAccess

# `hasWriteAccess` checks if we have write access on path
exports.hasWriteAccess = (path) ->
    return true if process.platform is 'win32' # temporary limitation on Windows platform
    
    stats = Fs.statSync Path.resolve (if path? then path else '.')
        
    canWrite = (owner, inGroup, mode) ->
        return  owner and (mode & 0x200) or     # User is owner and owner can write.
                inGroup and (mode & 0x20) or    # User is in group and group can write.
                (mode & 0x2)                    # Anyone can write.
                
    return 0 isnt canWrite (process.getuid() is stats.uid), (process.getgid() is stats.gid), stats.mode
    
#### getModifiedDate

# `getModifiedDate` service receives `where`, a system file path, and returns the given file last modification date
exports.getModifiedDate = (where, __) ->
    event = new Events.EventEmitter
    # First, it tries to resolve the `where` parameter to a local path
    {where, path, error} = resolve where, __
    if error? then process.nextTick(-> with_error event, error) ; return event
    
    # Then use the Fs `stat` service to get the file's last modification date
    Fs.stat path, (error, stats) ->
        return with_error event, error if error
        event.emit 'end', Date.parse(stats.mtime)
    event

#### getDirContent

# `getDirContent` returns the directory content as JSON string for the given `where` path ; resolve relative to process.cwd() or __.appdir if provided
exports.getDirContent = (where, __) ->
    event = new Events.EventEmitter
    result = []
    {where, path, error} = resolve where, __
    if error? then process.nextTick(-> with_error event, error) ; return event
    Fs.readdir path, (error, files) ->
        return with_error event, error if error
        files = files.sort()
        file_index = 0
        get_file_stats = ->
            if file_index < files.length
                filename = files[file_index++]
                Fs.stat path + '/' + filename, (error, stats) ->
                    return with_error event, error if error
                    
                    result.push name:filename, isDir:stats.isDirectory(), isFile:stats.isFile(), extension:Path.extname(filename), modifiedDate: Date.parse(stats.mtime)
                        
                    get_file_stats()
            else
                event.emit 'end', result
        get_file_stats()
    event

#### ensurePathExists

# `ensurePathExists` ensure that a path exists and creates directories if necessary; returns the path
exports.ensurePathExists = (path) ->
    file_path = path.split('/')
    file_name = file_path.pop()
    file_pathname = ''
    # Check the existence of every directory in the path
    for path in file_path
        if file_pathname is '' and path is '' then path = '/'
        file_pathname += (if file_pathname != '' then '/' else '') + path
        # Create the directory if non existent
        if file_pathname isnt '' and not Fs.existsSync file_pathname
            Fs.mkdirSync file_pathname, '755'
            
    file_pathname += (if file_pathname isnt '' then '/' else '') + file_name


#### 

# `setFilenameSuffix` append a suffix to a filename before the extension
exports.setFilenameSuffix = (filename, suffix) ->
    dirname = Path.dirname filename
    if dirname is '.' then dirname = ''
    if dirname isnt '' then dirname += '/'
    ext = Path.extname filename
    base = Path.basename filename, ext
    dirname + base + suffix + ext
                    
#### readDirDownSync

# `readDirDownSync` recursively read a directory and returns its content
exports.readDirDownSync = (dir, __) ->
    dir = normalize(dir, check_suffix:no, __)
    results = []
    files = Fs.readdirSync dir
    return results.sort() if files.length is 0
    i = 0
    next = () ->
        file = files[i++]
        unless file then return results.sort()
        file = dir + '/' + file
        stat = Fs.statSync file
        if stat and stat.isDirectory()
            results = results.concat exports.readDirDownSync file
            next()
        else
            results.push file
            next()
            
    next()

#### writeToFile

# `writeToFile` write the provided data to a file. Directories and file are created if necessary
exports.writeToFile = (path, data, __) ->
    event = new Events.EventEmitter
    
    normalized_path = normalize path, __
    if normalized_path is '' then process.nextTick(-> with_error event, 'Warning: empty path in writeToFile') ; return event
    
    file_pathname = exports.ensurePathExists normalized_path
    
    repo = resolve_repo normalized_path, __

    # Create the file if non existent
    unless Fs.existsSync file_pathname
        Fs.open file_pathname, 'a', '644', (err, fd) -> 
            unless err?
                Fs.close fd, (err) ->
                    # Add the file in Git index
                    new Git(cwd:repo.cwd).add(repo.path).on 'close', () ->
                        # Write the file content
                        Fs.writeFile file_pathname, data ? '', (err) ->
                            event.emit 'end', err
            else
                event.emit 'end', err
    # Directly write file content if the file already exists
    else
        Fs.writeFile file_pathname, data ? '', (err) ->
            event.emit 'end', err
    event

#### moveFile

# `moveFile` move a file content from a path to another one
exports.moveFile = (from, to, __) ->
    event = new Events.EventEmitter
    
    from = normalize from, __
    if from is '' then process.nextTick(-> with_error event, 'Warning: empty from in moveFile') ; return event

    repo = resolve_repo from, __
    
    # If file to move exists
    if Fs.existsSync from
        # Read its content
        Fs.readFile from, (err, data) ->
            unless err?
                # Destroy the original file
                Fs.unlink from, (err) ->
                    unless err?
                        # Remove it from the Git index
                        git = new Git cwd:repo.cwd
                        handler = git.add u:null, repo.path
                        handler.on 'close', () ->
                            # Move is a Remove if to is ''
                            return event.emit 'end', err if to is ''
                            
                            # Create a file with a new name and the original content
                            handler = exports.writeToFile to, data, __
                            handler.on 'end', (err) ->
                                event.emit 'end', err
                    else
                        event.emit 'end', err
            else
                event.emit 'end', err
    else
        process.nextTick -> event.emit 'end', "Source file does not exists: #{from}"
    event

#### removeFile

# `removeFile` remove a file
exports.removeFile = (path, __) ->
    event = new Events.EventEmitter
    path = normalize path, __
    
    repo = resolve_repo path, __
    
    # If file to move exists
    if Fs.existsSync path
        unless err?
            # Destroy the original file
            Fs.unlink path, (err) ->
                unless err?
                    # Remove it from the Git index
                    git = new Git cwd:repo.cwd
                    handler = git.add u:null, repo.path
                    handler.on 'close', () ->
                        event.emit 'end', err
                else
                    event.emit 'end', err
        else
            event.emit 'end', err
    else
        event.emit 'end', 'Source file does not exists'
    event

#### load

# `load` load one system file 
exports.load = (path, __) ->
    event = new Events.EventEmitter
    Fs.readFile require.resolve('../' + normalize path, __), (err, data) ->
        event.emit 'end', data.toString()
    event

#### grep

# `grep` look in file for a pattern; returns a list of filenames with last modif timestamp in seconds from EPOCH unless showdetails is specified
exports.grep = (pattern, with_case, show_details, __) ->
    if typeof with_case is 'string' then with_case = with_case is 'true'
    if typeof show_details is 'string' then show_details = show_details is 'true'
    
    event = new Events.EventEmitter
    results = []
    suffixes = ['.coffee', '.js', '.css', '.scss', '.json', '.txt', '.md', '.markdown', '.ck', '.chockup', '.log' ]
    if process.platform is 'win32'
        params = ['/R', '/S', pattern, (__?.appdir ? '.') + '\\*']
        unless with_case then params = ['/I'].concat params
        unless show_details then params = ['/M'].concat params
    else
        #params = ['-r', '--include', "'*.coffee'", '--include', "'*.js'", '--include', "'*.css'", '--include', "'*.markdown'", '--include', "'*.md'", pattern, __?.appdir ? '.',]
        params = ['-r'].concat(do -> s=[]; (s.push("--include"); s.push("'*#{suffix}'"); s) for suffix in suffixes; s).concat([pattern, __?.appdir ? '.',])
        unless with_case then params = ['-i'].concat params
        unless show_details then params = ['-l'].concat params else params = ['-n'].concat params
    
    command = ([if process.platform is 'win32' then 'findstr' else 'grep'].concat params).join(' ')
    if process.platform isnt 'win32' then unless show_details then command += " | while read line; do stat -c '%n %Y' $line; done"
    
    grep  = require('child_process').exec command
    grep.stdout.on 'data', (data) ->
        results = results.concat data.split(if process.platform is 'win32' then '\r\n' else '\n')
    grep.stderr.on 'data', (data) ->
    grep.on 'exit', (code) ->
        results = results.filter (item) ->
            [path] = item.toString().split ' '
            Path.extname(path) in suffixes
        results = results.map (item) ->
            [path, stamp] = item.toString().split ' '
            (Path.relative (__?.appdir ? '.'), path).replace(/\\/g, '/') + ' ' + stamp
        event.emit 'end', results.join '\n'

    event

#### Public Git services

#### commitToHistory

# `commitToHistory` commits current system files changes in Git repository 
exports.commitToHistory = (message, repository, __) ->
    event = new Events.EventEmitter
    repo = resolve_repo repository, __
    git = new Git cwd:repo.cwd
    handler = git.commit a:null, m:message
    handler.on 'close', () ->
        event.emit 'end', 'Done'
    event

#### loadFromHistory

# `loadFromHistory` load one system file from existing commit in Git repository 
exports.loadFromHistory = (commit_sha, path, repo_cwd, __) ->
    event = new Events.EventEmitter
    repo = resolve_repo path, __
    if repo_cwd isnt '' then repo.cwd = repo_cwd 
    git = new Git cwd:repo.cwd
    answer = ''
    handler = git.show '--raw', commit_sha + ':' + repo.path
    handler.on 'item', (item) ->
        answer += '' + item + '\n'
    handler.on 'close', () ->
        answer += handler.getBuffer().toString()
        event.emit 'end', answer

    event

#### getAvailableCommits

# `getAvailableCommits` return an html option string with available commits in Git for the provided `path`
exports.getAvailableCommits = (path, __) ->
    commits = null
    event = new Events.EventEmitter
    repo = resolve_repo path, __
    handler = new Git(cwd:repo.cwd).commits(follow:null,'name-status':null, repo.path)
    handler.on 'item', (commit) ->
        (commits ?= []).push sha:commit.sha, date:commit.author.date, message:commit.message, name:commit.name, repo:repo.cwd
    handler.on 'close', ->
        event.emit 'end', commits ? '[]'
            
    event

#### getGitStatus

# `getGitStatus` return current Git status for current git repository
exports.getGitStatus = (path, __) ->
    status = null
    event = new Events.EventEmitter
    repo = resolve_repo path, __
    handler = new Git(cwd:repo.cwd).status()
    handler.on 'item', (response) ->
        (status ?= []).push response
    handler.on 'close', ->
        event.emit 'end', status ? '[]'
            
    event

#### getFileDiff

# `getFileDiff` return current file Git diff
exports.getFileDiff = (path, __) ->
    diff = null
    event = new Events.EventEmitter
    repo = resolve_repo path, __
    handler = new Git(cwd:repo.cwd).diff(repo.path)
    handler.on 'item', (response) ->
        (diff ?= []).push response
    handler.on 'close', ->
        event.emit 'end', diff ? '[]'
            
    event


#### logConsoleAndErrors

# `logConsoleAndErrors` filters process.stdout.write and process.stderr.write to write their output in a file. This covers the following use cases:
#   process.stdout.write
#   process.stderr.write
#   console.log
#   console.dir
#   console.error
#   someStream.pipe(process.stdout);
#   throw new Error('Crash');
#   throw 'never do this';
#   throw undefined;

stdout_write = stderr_write = undefined

exports.logConsoleAndErrors = (path) ->
    return if stdout_write?

    stdout_write = process.stdout.write
    stderr_write = process.stderr.write
    
    write_stream = Fs.createWriteStream(path, { flags: 'a' })
    
    log = (chunk) ->
        chunk_ = switch 
            when typeof chunk is 'string' then chunk
            when Buffer.isBuffer chunk then chunk.toString 'binary'
            else chunk.toString()
        
        write_stream.write chunk_
        
        arguments[0] = chunk_
        arguments
        
        
    process.stdout.write = ((write) -> (chunk, encoding, fd) -> args = log.apply null, arguments ; write.apply process.stdout, args ; return)(process.stdout.write)
    process.stderr.write = ((write) -> (chunk, encoding, fd) -> args = log.apply null, arguments ; write.apply process.stderr, args ; return)(process.stderr.write)
    return
    
exports.unlogConsoleAndErrors = ->
    return unless stdout_write?
    process.stdout.write = stdout_write
    process.stderr.write = stderr_write
    return

exports.logWithTimestamp = ->
    funcs = 
        log: console.log
        info: console.info
        warn: console.warn
        error: console.error
    
    timestamp = -> '[' + (new Date).toISOString() + ']'
    
    Object.keys(funcs).forEach (k) ->
        console[k] = ->
            arguments0 = arguments[0]
            arguments[0] = Util.format(timestamp(), arguments0)
            funcs[k].apply console, arguments
            return
    return
    
#### Internal functions

#### normalize

# `normalize` 
#  - replace '-' by, or add sysdir value if appdir_relative and region is system
#  - add __.appdir to the path if region isnt system and not appdir_relative
#  - add .coffee extension to the provided `path` if it does not have one
normalize = (path, options, __) ->
    appdir_relative = options?.appdir_relative
    check_suffix = options?.check_suffix
    
    if arguments.length is 2 and not appdir_relative? and not check_suffix? then __ = options ; options = null
    
    appdir_relative ?= no
    check_suffix ?= yes
    
    path = path.trim()

    if __?
        is_system = no
        
        if __.where.trim() is path and __.region is 'system'
            is_system = yes
        else
        if (path.charAt(0) is '/' and path.charAt(1) is '-' and path.charAt(2) is '/') or (path.charAt(0) is '-' and path.charAt(1) is '/')
            path = path.substr (if path[0] is '-' then 2 else 3)
            is_system = yes
        else
        if (path.substr(0, __.sysdir.length + 2) is '/' + __.sysdir + '/') or (path.substr(0, __.sysdir.length + 1) is __.sysdir + '/')
            path = path.substr(__.sysdir.length + (if path.charAt(0) is '/' then 2 else 1))
            is_system = yes

        if is_system
            if appdir_relative
                path = __.sysdir + (if path[0] isnt '/' then '/' else '') + path
        else
            if not appdir_relative
                path = __.appdir + (if path[0] isnt '/' then '/' else '') + path
    else
        if (path.charAt(0) is '/' and path.charAt(1) is '-' and path.charAt(2) is '/') or (path.charAt(0) is '-' and path.charAt(1) is '/')
            if appdir_relative then throw "Don't know relative path from sysdir to appdir"
            else path = path.substr (if path[0] is '-' then 2 else 3)

    if (not check_suffix) or (path is '') or Path.extname(path) isnt '' then path else path + '.coffee'


#### resolve

# `resolve`  tries to resolve the `where` parameter to a local path 
resolve = (where, __) ->
    where_ = where
    
    try path = Path.resolve normalize where, check_suffix:no, __
    catch error then return {where, path, error}
    
    unless Fs.existsSync path
        path = normalize path
        where = normalize where
    
    unless Fs.existsSync path
        path = ''
        where = where_
        error = "File '#{where} does not exists'"
    
    {where, path, error}

#### resolve_repo

# `resolve_repo` adapts given path if in sysdir repository.
resolve_repo = (path, __) ->
    appdir_abs = Path.resolve(__?.appdir ? '.')
    
    switch path.charAt(0)
        when '.'
            git_dirname = Path.resolve path
            git_path = if git_dirname.indexOf(appdir_abs) is 0 then git_dirname.substr appdir_abs.length + 1 else path
        when '/' 
            git_path = path.substr 1
            git_dirname = appdir_abs + path
        else 
            git_path = path
            path = '/' + path
            git_dirname = appdir_abs + path

    while not Fs.existsSync(git_dirname + (if git_dirname[git_dirname.length - 1] isnt '/' then '/' else '') +  '.git')
        new_dirname = Path.resolve(git_dirname, '..')
        if new_dirname is git_dirname or new_dirname is appdir_abs
            cwd = __?.appdir ? '.'
            path = git_path
            return {cwd, path}
        else
            git_dirname = new_dirname

    {cwd:git_dirname, path:(appdir_abs + path).substr(git_dirname.length + 1)}

#### with_error

# `with_error` emits an `end` message containing the error message
with_error = (event, error) ->
    event.emit 'end', {error}

#### clientInterface

# `clientInterface` holds the file web editor written with CoffeeKup in CoffeeScript 
clientInterface = ->
    doctype 5
    
    html ->
        head ->
            meta
                'http-equiv':'content-type'
                'content':'text/html; charset:utf-8'
            style 
                type:"text/css" 
                media:"screen"
                """
                body {
                    overflow: hidden;
                    margin: 0;
                    background-color: lightgrey;
                    }
                
                #ide {
                    visibility: hidden;
                    }
                
                #toolbar {
                    }
                
                #editor {
                    margin: 0;
                    position: absolute;
                    top: 30px;
                    bottom: 0;
                    left: 0;
                    right: 0;
                    font-size: 14px;
                    }
                #editor * {
                    -webkit-overflow-scrolling: touch;
                    }
                """
        body ->
            script src:"/static/vendor/mootools/mootools-core.js", type:"text/javascript", charset:"utf-8"
            script src:"/static/vendor/ace/ace.js", type:"text/javascript", charset:"utf-8"
            script src:"/static/vendor/ace/mode-coffee.js", type:"text/javascript", charset:"utf-8"
            script src:"/static/vendor/ace/mode-javascript.js", type:"text/javascript", charset:"utf-8"
            script src:"/static/vendor/ace/mode-css.js", type:"text/javascript", charset:"utf-8"
            script src:"/static/vendor/ace/mode-text.js", type:"text/javascript", charset:"utf-8"
            script src:"/static/vendor/ace/mode-html.js", type:"text/javascript", charset:"utf-8"
            script src:"/static/vendor/ace/mode-markdown.js", type:"text/javascript", charset:"utf-8"
            script src:"/static/vendor/ace/theme-coffee.js", type:"text/javascript", charset:"utf-8"
    
            div '#ide', ->
                div '#toolbar', ->
                    input '#save_button',
                        type:'button'
                        value:'Save it'
                        onclick:'javascript:_ide.save()'
                    select '#commits',
                        onchange:'javascript:_ide.load()'
                        -> text commits
                    input '#commit_message',
                        type:'text'
                    input 
                        type:'button'
                        value:'Commit'
                        onclick:'javascript:_ide.commit()'
                div '#editor', -> text source
            
            text '<script>_ide = {}; _sofkey = ' + (if backdoor_key isnt '' then '"' + backdoor_key + '"' else 'null') + '; _where = "' + where + '"; _modifiedDate = parseInt(' + (+modifiedDate) + ');</script>'
            
            coffeescript ->
                editor = null
                codeMode = 'opened'
                sofkey = _sofkey
                where = _where
                modifiedDate = _modifiedDate
                                
                _ide.load =  ->
                    sha = document.id('commits').get 'value'
                    if sha is ''
                        url = (if sofkey? then '/!/' + sofkey else '') + '/-/server/file?sodowhat=load&path=' + where + '&how=raw'
                    else
                        url = (if sofkey? then '/!/' + sofkey else '') + '/-/server/file?sodowhat=loadFromHistory&commit_sha=' + sha + '&path=' + where + '.coffee' + '&how=raw'
                    new Request
                        url: url
                        onSuccess: (responseText) ->
                            # do not use responseText as it is filtered
                            editor.getSession().setValue @response.text
                        onFailure: (xhr) ->
                            alert 'Error: ' + xhr.status
                    .get()
                    
                _ide.save = ->
                    data = editor.getSession().getValue()
                    if data? and (data isnt '')
                        myRequest = new Request
                            url: (if sofkey? then '/!/' + sofkey else '') + '/-/' + where + '?so=move&how=raw'
                            onSuccess: (responseText) ->
                                modifiedDate = parseInt responseText
                                $('save_button').setStyle('color', '#000000')
                            onFailure: (xhr) ->
                                alert 'Error: ' + xhr.status
                        myRequest.post data

                _ide.commit = ->
                    message = document.id('commit_message').get 'value'
                    new Request
                        url: (if sofkey? then '/!/' + sofkey else '') + '/-/server/file?sodowhat=commitToHistory&message=' + message + '&how=raw'
                        onSuccess: (responseText) ->
                            alert('File "' + where + '" commited. ' + responseText)
                        onFailure: (xhr) ->
                            alert('Error: ' + xhr.status)
                    .get();
                
                _ide.toggleCodeMode = (mode, scope, size) ->
                    isCommentRow = (row) ->
                        tokens = editor.session.getTokens(row, row)[0].tokens
                        for token in tokens
                            if /^comment/.test(token.type)
                                return true
                            else 
                                unless /^text/.test(token.type)
                                    return false
                        false
                    
                    toggleCode = (start, end) ->
                        range = editor.selection.getRange()
                        range.start.column = 0; range.start.row = start;
                        range.end.column = editor.session.doc.getLine(end - 1).length; range.end.row = end - 1
                        unless range.isEmpty() then editor.session.addFold '...', range
                        end + 1
                    
                    if scope is 'full'
                        if codeMode is 'opened'
                            start = 0; end = 0; catched = false
                            for i in [0...editor.session.doc.getLength()]
                                if isCommentRow(i) is (mode is 'comment')
                                    if (size is 'line') and catched
                                        end += 1
                                    else if end > start
                                        start = end = toggleCode start, end
                                    else 
                                        start = end += 1
                                    
                                    catched = true
                                else 
                                    end += 1
                                    catched = false
                                    
                            if end > start then toggleCode start, end
                            codeMode = 'closed'
                        else
                            range = editor.selection.getRange()
                            range.start.column = 0; range.start.row = 0
                            end = editor.session.doc.getLength() - 1
                            range.end.column = editor.session.doc.getLine(end).length; range.end.row = end
                            folds = editor.session.getFoldsInRange range
                            if folds.length > 0 then editor.session.removeFolds folds
                            codeMode = 'opened'
                    else
                        range = editor.selection.getRange()
                        start = range.start.row; end = start
                        fold = editor.session.getFoldAt range.start.row, range.start.column
                        if fold
                            if range.isEmpty() then editor.session.expandFold fold
                        else
                            if isCommentRow start
                                while isCommentRow(start) then start = end += 1
                            while (start >= 0) and not isCommentRow(start - 1) then start += -1
                            while (end + 1 < editor.session.doc.getLength()) and not isCommentRow(end + 1) then end += 1
                            if end + 1 > start
                                toggleCode start, end + 1
                                editor.selection.moveCursorTo start, 0
                
                _ide.refresh_rate = 2 * 60 * 1000
                
                _ide.get_extension = (path) ->
                        if (path = path.substr(1 + path.indexOf '/')).indexOf('.') is -1 then '' else '.' + path.split('.')[-1..][0]
                
                keepUptodate = ->
                    new Request
                        url: (if sofkey? then '/!/' + sofkey else '') + '/-/server/file?sodowhat=getModifiedDate&path=' + where + '&how=raw'
                        onSuccess: (responseText) ->
                            if modifiedDate < parseInt responseText
                                window.location.reload()
                        onFailure: (xhr) ->
                            alert('Error: ' + xhr.status)
                    .get();
                    
                    setTimeout keepUptodate, _ide.refresh_rate
                    
                window.addEvent 'domready', ->
    
                    mode = 'ace/mode/' + switch _ide.get_extension where ? ''
                        when '.coffee' then 'coffee'
                        when '.js' then 'javascript'
                        when '.json' then 'javascript'
                        when '.css' then 'css'
                        when '.html' then 'html'
                        when '.txt' then 'text'
                        when '.markdown', '.md' then 'markdown'
                        else 'coffee'
                    Mode = require(mode).Mode                    
                    
                    set_editor = (id) ->
                        e = ace.edit id
                        try e.setScrollSpeed(2)
                        e.setShowPrintMargin false
                        setTimeout (-> e.setTheme 'ace/theme/coffee'; document.getElementById('ide').style.visibility = 'inherit'), 200
                        e.setShowInvisibles yes
                        
                        e.getSession().setMode new Mode()
                        e.getSession().setUseSoftTabs true
                        e
                        
                    editor = set_editor 'editor'

                    editor.getSession().on 'change', ->
                        button = $('save_button')
                        if button.getStyle('color') isnt 'red'
                            button.setStyle 'color', 'red'
                        true
                        
                    editor.focus()
                    
                    setTimeout keepUptodate, _ide.refresh_rate
            
                    commands = editor.commands
                    commands.addCommand
                        name: "save"
                        bindKey:
                            win: "Ctrl-S",mac: "Command-S"
                        exec: -> _ide.save()
                    commands.addCommand
                        name: "find next"
                        bindKey:
                            win: "F3|Ctrl-G"
                        exec: -> editor.findNext()
                    commands.addCommand
                        name: "find previous"
                        bindKey:
                            win: "Shift-F3|Shift-Ctrl-G"
                        exec: -> editor.findPrevious()
                    commands.addCommand
                        name: "toggle code mode"
                        bindKey:
                            win: "Alt-I", mac: "Alt-I"
                        exec: -> _ide.toggleCodeMode 'comment', 'one', 'block'
                    commands.addCommand
                        name: "toggle full one line code mode"
                        bindKey:
                            win: "Alt-Shift-U", mac: "Alt-Shift-U"
                        exec: -> _ide.toggleCodeMode 'comment', 'full', 'line'
                    commands.addCommand
                        name: "toggle full code mode"
                        bindKey:
                            win: "Alt-Shift-I", mac: "Alt-Shift-I"
                        exec: -> _ide.toggleCodeMode 'comment', 'full', 'block'
                    commands.addCommand
                        name: "toggle no comment mode"
                        bindKey:
                            win: "Alt-Shift-O", mac: "Alt-Shift-O"
                        exec: -> _ide.toggleCodeMode 'code', 'full', 'block'
                    