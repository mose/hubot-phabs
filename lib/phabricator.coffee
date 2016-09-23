# Description:
#   requests Phabricator Conduit api
#
# Dependencies:
#
# Configuration:
#  PHABRICATOR_URL
#  PHABRICATOR_API_KEY
#  PHABRICATOR_BOT_PHID
#  PHABRICATOR_TRUSTED_USERS
#
# Author:
#   mose

querystring = require 'querystring'
moment = require 'moment'
Promise = require 'bluebird'

class Phabricator

  statuses: {
    'open': 'open',
    'opened': 'open',
    'resolved': 'resolved',
    'resolve': 'resolved',
    'closed': 'resolved',
    'close': 'resolved',
    'wontfix': 'wontfix',
    'noway': 'wontfix',
    'invalid': 'invalid',
    'rejected': 'invalid',
    'spite': 'spite',
    'lame': 'spite'
  }

  priorities: {
    'unbreak': 100,
    'broken': 100,
    'need triage': 90,
    'none': 90,
    'unknown': 90,
    'low': 25,
    'normal': 50,
    'high': 80,
    'urgent': 80,
    'wish': 0
  }

  constructor: (@robot, env) ->
    storageLoaded = =>
      @data = @robot.brain.data.phabricator ||= {
        projects: { },
        aliases: { },
        templates: { },
        blacklist: [ ],
        users: { },
        bot_phid: env.PHABRICATOR_BOT_PHID
      }
      @robot.logger.debug 'Phabricator Data Loaded: ' + JSON.stringify(@data, null, 2)
    @robot.brain.on 'loaded', storageLoaded
    storageLoaded() # just in case storage was loaded before we got here
    @data.templates ?= { }
    @data.blacklist ?= [ ]
    @data.users ?= { }

  ready: ->
    if not process.env.PHABRICATOR_URL
      @robot.logger.error 'Error: Phabricator url is not specified'
    if not process.env.PHABRICATOR_API_KEY
      @robot.logger.error 'Error: Phabricator api key is not specified'
    unless (process.env.PHABRICATOR_URL? and process.env.PHABRICATOR_API_KEY?)
      return false
    true

  request: (query, endpoint) =>
    return new Promise (res, err) =>
      query['api.token'] = process.env.PHABRICATOR_API_KEY
      body = querystring.stringify(query)
      @robot.http(process.env.PHABRICATOR_URL)
        .path("api/#{endpoint}")
        .get(body) (error, result, payload) ->
          if result?
            switch result.statusCode
              when 200
                if result.headers['content-type'] is 'application/json'
                  json = JSON.parse(payload)
                  if json.error_info?
                    err json.error_info
                  else
                    res json
                else
                  err 'api did not deliver json'
              else
                err "http error #{result.statusCode}"
          else
            err "#{error.code} #{error.message}"


  isBlacklisted: (id) ->
    @data.blacklist.indexOf(id) > -1

  blacklist: (id) ->
    unless @isBlacklisted(id)
      @data.blacklist.push id

  unblacklist: (id) ->
    if @isBlacklisted(id)
      pos = @data.blacklist.indexOf id
      @data.blacklist.splice(pos, 1)

  getBotPHID: =>
    return new Promise (res, err) =>
      if @data.bot_phid?
        res @data.bot_phid
      else
        @request({ }, 'user.whoami')
          .then (body) =>
            @data.bot_phid = body.result.phid
            res @data.bot_phid
          .catch (e) ->
            err e

  getFeed: (payload) =>
    return new Promise (res, err) =>
      if /^PHID-TASK-/.test payload.storyData.objectPHID
        query = {
          'constraints[phids][0]': payload.storyData.objectPHID,
          'attachments[projects]': 1
        }
        data = @data
        @request(query, 'maniphest.search')
          .then (body) ->
            announces = { message: payload.storyText }
            announces.rooms = []
            if body.result.data?
              for phid in body.result.data[0].attachments.projects.projectPHIDs
                for name, project of data.projects
                  if project.phid? and phid is project.phid
                    project.feeds ?= [ ]
                    for room in project.feeds
                      if announces.rooms.indexOf(room) is -1
                        announces.rooms.push room
            res announces
          .catch (e) ->
            err e
      else
        err 'no room to announce in'

  getProject: (project) ->
    return new Promise (res, err) =>
      project = project
      if @data.projects[project]?
        projectData = @data.projects[project]
        projectData.name = project
      else
        for a, p of @data.aliases
          if a is project and @data.projects[p]?
            projectData = @data.projects[p]
            projectData.name = p
            break
      aliases = []
      if projectData?
        for a, p of @data.aliases
          if p is projectData.name
            aliases.push a
        if projectData.phid?
          res { aliases: aliases, data: projectData }
        else
          @requestProject(projectData.name)
            .then (projectinfo) ->
              projectData.phid = projectinfo.phid
              res { aliases: aliases, data: projectData }
            .catch (e) ->
              err e
      else
        data = @data
        query = { 'names[0]': project }
        @requestProject(project)
          .then (projectinfo) ->
            data.projects[projectinfo.name] = projectinfo
            res { aliases: aliases, data: projectinfo }
          .catch (e) ->
            err e

  requestProject: (project_name) ->
    return new Promise (res, err) =>
      query = { 'names[0]': project_name }
      @request(query, 'project.query')
      .then (body) ->
        data = body.result.data
        if data.length > 0 or Object.keys(data).length > 0
          phid = Object.keys(data)[0]
          name = data[phid].name
          res { name: name, phid: phid }
        else
          err "Sorry, #{project_name} not found."
      .catch (e) ->
        err e

  getUser: (from, user) =>
    return new Promise (res, err) =>
      unless user.id?
        user.id = user.name
      if @data.users[user.id]?.phid?
        res @data.users[user.id].phid
      else
        @data.users[user.id] ?= {
          name: user.name,
          id: user.id
        }
        if user.phid?
          @data.users[user.id].phid = user.phid
          res @data.users[user.id].phid
        else
          email = @data.users[user.id].email_address or
                  @robot.brain.userForId(user.id)?.email_address or
                  user.email_address
          unless email
            err @_ask_for_email(from, user)
          else
            user = @data.users[user.id]
            query = { 'emails[0]': email }
            @request(query, 'user.query')
            .then (body) ->
              if body.result['0']?
                user.phid = body['result']['0']['phid']
                res user.phid
              else
                err "Sorry, I cannot find #{email} :("

  _ask_for_email: (from, user) ->
    if from.name is user.name
      "Sorry, I can't figure out your email address :( " +
      'Can you tell me with `.phab me as <email>`?'
    else
      if @robot.auth? and (@robot.auth.hasRole(from, ['phadmin']) or
          @robot.auth.isAdmin(from))
        "Sorry, I can't figure #{user.name} email address. " +
        "Can you help me with `.phab user #{user.name} = <email>`?"
      else
        "Sorry, I can't figure #{user.name} email address. " +
        'Can you ask them to `.phab me as <email>`?'

  recordId: (user, id) ->
    @data.users[user.id] ?= {
      name: "#{user.name}",
      id: "#{user.id}"
    }
    @data.users[user.id].lastTask = moment().utc().format()
    @data.users[user.id].lastId = id

  getId: (user, id = null) ->
    return new Promise (res, err) =>
      @data.users[user.id] ?= {
        name: "#{user.name}",
        id: "#{user.id}"
      }
      user = @data.users[user.id]
      if id?
        if id is 'last'
          if user? and user.lastId?
            res user.lastId
          else
            err "Sorry, you don't have any task active."
        else
          @recordId user, id
          res id
      else
        user.lastTask ?= moment().utc().format()
        expires_at = moment(user.lastTask).add(10, 'minutes')
        if user.lastId? and moment().utc().isBefore(expires_at)
          user.lastTask = moment().utc().format()
          res user.lastId
        else
          err "Sorry, you don't have any task active right now."

  getUserByPhid: (phid) ->
    return new Promise (res, err) =>
      if phid?
        query = { 'phids[0]': phid }
        @request(query, 'user.query')
        .then (body) ->
          if body['result']['0']?
            res body['result']['0']['userName']
          else
            res 'unknown'
        .catch (e) ->
          err e
      else
        res 'nobody'

  getPermission: (user, group) =>
    return new Promise (res, err) =>
      if group is 'phuser' and process.env.PHABRICATOR_TRUSTED_USERS is 'y'
        isAuthorized = true
      else
        isAuthorized = @robot.auth?.hasRole(user, [group, 'phadmin']) or
                       @robot.auth?.isAdmin(user)
      if @robot.auth? and not isAuthorized
        err "You don't have permission to do that."
      else
        res()

  taskInfo: (id) ->
    query = { 'task_id': id }
    @request query, 'maniphest.info'

  getTask: (id) ->
    query = { 'task_id': id }
    @request query, 'maniphest.info'

  fileInfo: (id) ->
    query = { 'id': id }
    @request query, 'file.info'

  pasteInfo: (id) ->
    query = { 'ids[0]': id }
    @request query, 'paste.query'

  genericInfo: (name) ->
    query = { 'names[]': name }
    @request query, 'phid.lookup'

  searchTask: (phid, terms) ->
    query = {
      'constraints[fulltext]': terms,
      'constraints[statuses][0]': 'open',
      'constraints[projects][0]': phid,
      'order': 'newest',
      'limit': '3'
    }
    @request query, 'maniphest.search'

  searchAllTask: (phid, terms) ->
    query = {
      'constraints[fulltext]': terms,
      'constraints[projects][0]': phid,
      'order': 'newest',
      'limit': '3'
    }
    @request query, 'maniphest.search'

  createTask: (params) ->
    params.adapter = @robot.adapterName or 'test'
    @getBotPHID()
    .then (bot_phid) =>
      params.bot_phid = bot_phid
      if params.user?
        if not params.user?.name?
          params.user = { name: params.user }
      else
        params.user = { name: @robot.name, phid: params.bot_phid }
      @getTemplate(params.template)
    .then (description) =>
      if description?
        if params.description?
          params.description += "\n\n#{description}"
        else
          params.description = description
      @getProject(params.project)
    .then (projectparams) =>
      params.projectphid = projectparams.data.phid
      @getUser(params.user, params.user)
    .then (userPHID) =>
      query = {
        'transactions[0][type]': 'title',
        'transactions[0][value]': "#{params.title}",
        'transactions[1][type]': 'comment',
        'transactions[1][value]': "(created by #{params.user.name} on #{params.adapter})",
        'transactions[2][type]': 'subscribers.add',
        'transactions[2][value][0]': "#{userPHID}",
        'transactions[3][type]': 'subscribers.remove',
        'transactions[3][value][0]': "#{params.bot_phid}",
        'transactions[4][type]': 'projects.add',
        'transactions[4][value][]': "#{params.projectphid}"
      }
      next = 5
      if params.description?
        query["transactions[#{next}][type]"] = 'description'
        query["transactions[#{next}][value]"] = "#{params.description}"
        next += 1
      if params.assign? and @data.users?[params.assign]?.phid
        owner = @data.users[params.assign]?.phid
        query["transactions[#{next}][type]"] = 'owner'
        query["transactions[#{next}][value]"] = owner
      @request(query, 'maniphest.edit')
    .then (body) ->
      id = body.result.object.id
      url = process.env.PHABRICATOR_URL + "/T#{id}"
      { id: id, url: url, user: params.user }

  createPaste: (user, title) ->
    adapter = @robot.adapterName
    bot_phid = null
    @getBotPHID()
    .bind(bot_phid)
    .then (bot_phid) =>
      @getUser(user, user)
    .then (userPhid) =>
      query = {
        'transactions[0][type]': 'title',
        'transactions[0][value]': "#{title}",
        'transactions[1][type]': 'text',
        'transactions[1][value]': "(created by #{user.name} on #{adapter})",
        'transactions[2][type]': 'subscribers.add',
        'transactions[2][value][0]': "#{userPhid}",
        'transactions[3][type]': 'subscribers.remove',
        'transactions[3][value][0]': "#{@bot_phid}"
      }
      @request(query, 'paste.edit')
    .then (body) ->
      body.result.object.id

  addComment: (user, id, comment) ->
    @getBotPHID()
    .then (bot_phid) =>
      query = {
        'objectIdentifier': id,
        'transactions[0][type]': 'comment',
        'transactions[0][value]': "#{comment} (#{user.name})",
        'transactions[1][type]': 'subscribers.remove',
        'transactions[1][value][0]': "#{bot_phid}"
      }
      @request(query, 'maniphest.edit')
    .then (body) ->
      id

  changeTags: (user, id, alltags) ->
    @getBotPHID()
    .bind({ botphid: null })
    .then (botphid) =>
      @botphid = botphid
      @getUser(user, user)
    .then (userPhid) =>
      query = { 'task_id': id }
      @request(query, 'maniphest.info')
    .then (body) =>
      @makeTags(body.result.projectPHIDs, alltags)
    .then (tags) =>
      [ add, remove, messages ] = tags
      query = {
        'objectIdentifier': id,
        'transactions[0][type]': 'subscribers.remove',
        'transactions[0][value][0]': "#{@botphid}",
        'transactions[1][type]': 'comment',
        'transactions[1][value]': "tags changed by #{user.name}"
      }
      ind = 1
      if add.length > 0
        ind += 1
        query["transactions[#{ind}][type]"] = 'projects.add'
        x = add.map (t) -> t.phid
        for p in x 
          query["transactions[#{ind}][value][]"] = p
        messages.push "T#{id} added to #{add.map((t) -> t.tag).join(', ')}"
      if remove.length > 0
        ind += 1
        query["transactions[#{ind}][type]"] = 'projects.remove'
        x = remove.map (t) -> t.phid
        for p in x
          query["transactions[#{ind}][value][]"] = p
        messages.push "T#{id} removed from #{remove.map((t) -> t.tag).join(', ')}"
      if ind > 1
        @request(query, 'maniphest.edit')
          .then (body) =>
            messages
      else
        [ "No action needed." ]

  makeTags: (projs, alltags) ->
    ins = alltags.trim().split('not in ')
    tagin = ins.shift().split('in ').map (e) -> e.trim()
    tagin.shift()
    tagout = [ ]
    for t in ins
      els = t.split('in ')
      tagout.push(els.shift().trim())
      tagin = tagin.concat(els.map (e) -> e.trim())
    msg = [ ]
    add = Promise.map tagin, (tag) =>
      @getProject(tag)
      .then (projectData) ->
        phid = projectData.data.phid
        if phid not in projs
          { tag: tag, phid: phid }
        else
          msg.push "already in #{tag}"
          null
    .filter (tag) ->
      tag?
    remove = Promise.map tagout, (tag) =>
      @getProject(tag)
      .then (projectData) ->
        phid = projectData.data.phid
        if phid in projs
          { tag: tag, phid: phid }
        else
          msg.push "not in #{tag}"
          null
    .filter (tag) ->
      tag?
    return Promise.all([add, remove, msg])

  updateStatus: (user, id, status, comment) ->
    userPhid = null
    @getUser(user, user)
    .then (userPhid) =>
      @getBotPHID()
    .then (bot_phid) =>
      query = {
        'objectIdentifier': id,
        'transactions[0][type]': 'status',
        'transactions[0][value]': @statuses[status],
        'transactions[1][type]': 'subscribers.remove',
        'transactions[1][value][0]': "#{bot_phid}",
        'transactions[2][type]': 'owner',
        'transactions[2][value]': userPhid,
        'transactions[3][type]': 'comment'
      }
      if comment?
        query['transactions[3][value]'] = "#{comment} (#{user.name})"
      else
        query['transactions[3][value]'] = "status set to #{status} by #{user.name}"
      @request(query, 'maniphest.edit')
    .then (body) ->
      id

  updatePriority: (user, id, priority, comment) ->
    userPhid = null
    @getUser(user, user)
    .then (userPhid) =>
      @getBotPHID()
    .then (bot_phid) =>
      query = {
        'objectIdentifier': id,
        'transactions[0][type]': 'priority',
        'transactions[0][value]': @priorities[priority],
        'transactions[1][type]': 'subscribers.remove',
        'transactions[1][value][0]': "#{bot_phid}",
        'transactions[2][type]': 'owner',
        'transactions[2][value]': userPhid,
        'transactions[3][type]': 'comment'
      }
      if comment?
        query['transactions[3][value]'] = "#{comment} (#{user.name})"
      else
        query['transactions[3][value]'] = "priority set to #{priority} by #{user.name}"
      @request(query, 'maniphest.edit')
    .then (body) ->
      id

  assignTask: (id, userphid) ->
    @getBotPHID()
    .then (bot_phid) =>
      query = {
        'objectIdentifier': "T#{id}",
        'transactions[0][type]': 'owner',
        'transactions[0][value]': "#{userphid}",
        'transactions[1][type]': 'subscribers.remove',
        'transactions[1][value][0]': "#{bot_phid}"
      }
      @request(query, 'maniphest.edit')
    .then (body) ->
      body.result.object.id

  listTasks: (projphid) ->
    query = {
      'projectPHIDs[0]': "#{projphid}",
      'status': 'status-open'
    }
    @request query, 'maniphest.query'

  nextCheckbox: (user, id, key) ->
    return new Promise (res, err) =>
      query = { task_id: id }
      @request(query, 'maniphest.info')
      .then (body) =>
        @recordId user, id
        lines = body.result.description.split('\n')
        reg = new RegExp("^\\[ \\] .*#{key or ''}", 'i')
        found = null
        for line in lines
          if reg.test line
            found = line
            break
        if found?
          res found
        else
          if key?
            err "The task T#{id} has no unchecked checkbox matching #{key}."
          else
            err "The task T#{id} has no unchecked checkboxes."
      .catch (e) ->
        err e

  prevCheckbox: (user, id, key) ->
    return new Promise (res, err) =>
      query = { task_id: id }
      @request(query, 'maniphest.info')
      .then (body) =>
        @recordId user, id
        lines = body.result.description.split('\n').reverse()
        reg = new RegExp("^\\[x\\] .*#{key or ''}", 'i')
        found = null
        for line in lines
          if reg.test line
            found = line
            break
        if found?
          res found
        else
          if key?
            err "The task T#{id} has no checked checkbox matching #{key}."
          else
            err "The task T#{id} has no checked checkboxes."
      .catch (e) ->
        err e

  updateTask: (id, description, comment) =>
    @getBotPHID()
    .then (bot_phid) =>
      editquery = {
        'objectIdentifier': "T#{id}",
        'transactions[0][type]': 'description'
        'transactions[0][value]': "#{description}"
        'transactions[1][type]': 'subscribers.remove',
        'transactions[1][value][0]': "#{bot_phid}",
        'transactions[2][type]': 'comment',
        'transactions[2][value]': "#{comment}"
      }
      @request(editquery, 'maniphest.edit')

  checkCheckbox: (user, id, key, withNext, usercomment) ->
    return new Promise (res, err) =>
      query = { task_id: id }
      @request(query, 'maniphest.info')
      .then (body) =>
        @recordId user, id
        lines = body.result.description.split('\n')
        reg = new RegExp("^\\[ \\] .*#{key or ''}", 'i')
        found = null
        foundNext = null
        updated = [ ]
        extra = if key? then " matching #{key}" else ''
        for line in lines
          if not found? and reg.test line
            line = line.replace('[ ] ', '[x] ')
            found = line
          else if withNext? and found? and not foundNext? and reg.test line
            foundNext = line
          updated.push line
        if found?
          comment = "#{user.name} checked:\n#{found}"
          comment += "\n#{usercomment}" if usercomment?
          description = updated.join('\n')
          @updateTask(id, description, comment)
          .then (body) ->
            if withNext? and not foundNext?
              foundNext = "there is no more unchecked checkbox#{extra}."
            res [ found, foundNext ]
          .catch (e) ->
            err e
        else
          err "The task T#{id} has no unchecked checkbox#{extra}."
      .catch (e) ->
        err e

  uncheckCheckbox: (user, id, key, withNext, usercomment) ->
    return new Promise (res, err) =>
      query = { task_id: id }
      @request(query, 'maniphest.info')
      .then (body) =>
        @recordId user, id
        lines = body.result.description.split('\n').reverse()
        reg = new RegExp("^\\[x\\] .*#{key or ''}", 'i')
        found = null
        foundNext = null
        updated = [ ]
        extra = if key? then " matching #{key}" else ''
        for line in lines
          if not found? and reg.test line
            line = line.replace('[x] ', '[ ] ')
            found = line
          else if withNext? and found? and not foundNext? and reg.test line
            foundNext = line
          updated.push line
        if found?
          comment = "#{user.name} unchecked:\n#{found}"
          comment += "\n#{usercomment}" if usercomment?
          description = updated.reverse().join('\n')
          @updateTask(id, description, comment)
          .then (body) ->
            if withNext? and not foundNext?
              foundNext = "there is no more checked checkbox#{extra}."
            res [ found, foundNext ]
          .catch (e) ->
            err e
        else
          err "The task T#{id} has no checked checkbox#{extra}."
      .catch (e) ->
        err e


  # templates ---------------------------------------------------

  getTemplate: (name) =>
    return new Promise (res, err) =>
      if name?
        if @data.templates[name]?
          query = {
            task_id: @data.templates[name].task
          }
          @request(query, 'maniphest.info')
          .then (body) ->
            res body.result.description
          .catch (e) ->
            err e
        else
          err "There is no template named '#{name}'."
      else
        res null

  addTemplate: (name, taskid) ->
    return new Promise (res, err) =>
      if @data.templates[name]?
        err "Template '#{name}' already exists."
      else
        data = @data
        @taskInfo(taskid)
        .then (body) ->
          data.templates[name] = { task: taskid }
          res 'Ok'
        .catch (e) ->
          err e

  showTemplate: (name) ->
    return new Promise (res, err) =>
      if @data.templates[name]?
        res @data.templates[name]
      else
        err "Template '#{name}' was not found."

  searchTemplate: (term) ->
    return new Promise (res, err) =>
      back = [ ]
      for name, template of @data.templates
        if new RegExp(term).test name
          back.push { name: name, task: template.task }
      if back.length is 0
        if term?
          err "No template matches '#{term}'."
        else
          err 'There is no template defined.'
      else
        res back
        
  removeTemplate: (name) ->
    return new Promise (res, err) =>
      if @data.templates[name]?
        delete @data.templates[name]
        res 'Ok'
      else
        err "Template '#{name}' was not found."

  updateTemplate: (name, taskid) ->
    return new Promise (res, err) =>
      if @data.templates[name]?
        data = @data
        @taskInfo(taskid)
        .then (body) ->
          data.templates[name] = { task: taskid }
          res 'Ok'
        .catch (e) ->
          err e
      else
        err "Template '#{name}' was not found."

  renameTemplate: (name, newname) ->
    return new Promise (res, err) =>
      if @data.templates[name]?
        if @data.templates[newname]?
          err "Template '#{newname}' already exists."
        else
          @data.templates[newname] = { task: @data.templates[name].task }
          delete @data.templates[name]
          res 'Ok'
      else
        err "Template '#{name}' was not found."



module.exports = Phabricator
