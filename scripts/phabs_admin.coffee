# Description:
#   enable communication with Phabricator via Conduit api
#
# Dependencies:
#
# Configuration:
#   PHABRICATOR_URL
#   PHABRICATOR_API_KEY
#
# Commands:
#   hubot phad projects
#   hubot phad delete <project>
#   hubot phad info <project>
#   hubot phad refresh <project>
#   hubot phad alias <project> as <alias>
#   hubot phad forget <alias>
#   hubot phad feed <project> to <room>
#   hubot phad remove <project> from <room>
#   hubot phad removeall from <room>
#   hubot phad columns <project>
#
# Author:
#   mose

Phabricator = require '../lib/phabricator'
moment = require 'moment'
path = require 'path'

module.exports = (robot) ->

  robot.phab ?= new Phabricator robot, process.env
  phab = robot.phab

  #   hubot phad projects
  robot.respond /phad (?:projects|list) *$/, (msg) ->
    projects = Object.keys(phab.data.projects).filter (i) ->
      i isnt '*'
    if projects.length > 0
      msg.send "Known Projects: #{projects.join(', ')}"
    else
      msg.send 'There is no project.'

  #   hubot phad delete <project>
  robot.respond /phad del(?:ete)? (.+) *$/, (msg) ->
    project = msg.match[1]
    phab.getPermission(msg.envelope.user, 'phadmin')
    .then ->
      if phab.data.projects[project]?
        delete phab.data.projects[project]
        for alias, proj of phab.data.aliases
          delete phab.data.aliases[alias] if proj is project
        msg.send "#{project} erased from memory."
      else
        msg.send "#{project} not found in memory."
    .catch (e) ->
      msg.send e.message or e

  #   hubot phad info|refresh <project>
  robot.respond /phad (info|show|refresh) (.+) *$/, (msg) ->
    refresh = (msg.match[1] is 'refresh')
    project = msg.match[2]
    phab.getProject(project, refresh)
    .then (proj) ->
      response = "'#{project}' is"
      if proj.data.parent?
        response += " '#{proj.data.parent}/#{proj.data.name}'"
      else
        response += " '#{proj.data.name}'"
      if proj.aliases? and proj.aliases.length > 0
        response += " (aka #{proj.aliases.join(', ')})"
      else
        response += ', with no alias'
      if proj.data.feeds? and proj.data.feeds.length > 0
        response += ", announced on #{proj.data.feeds.join(', ')}"
      else
        response += ', with no feed'
      if proj.data.columns? and Object.keys(proj.data.columns).length > 0
        response += ", columns #{Object.keys(proj.data.columns).join(', ')}"
      else
        response += ', and no columns'
      if proj.data.parent?
        response += " (child of #{proj.data.parent})"
      response += '.'
      msg.send response
    .catch (e) ->
      msg.send e.message or e

  #   hubot phad alias <project> as <alias>
  robot.respond /phad alias (.+) as (.+)$/, (msg) ->
    project = msg.match[1]
    alias = msg.match[2]
    phab.getPermission(msg.envelope.user, 'phadmin')
    .then ->
      phab.getProject(project)
    .then (proj) ->
      if phab.data.aliases[alias]?
        msg.send "The alias '#{alias}' already exists for project '#{phab.data.aliases[alias]}'."
      else
        if proj.data.parent?
          fullname = "#{proj.data.parent}/#{proj.data.name}"
        else
          fullname = proj.data.name
        phab.data.aliases[alias] = fullname
        msg.send "Ok, '#{fullname}' will be known as '#{alias}'."
    .catch (e) ->
      msg.send e.message or e

  #   hubot phad forget <alias>
  robot.respond /phad forget (.+)$/, (msg) ->
    alias = msg.match[1]
    phab.getPermission(msg.envelope.user, 'phadmin')
    .then ->
      if phab.data.aliases[alias]
        delete phab.data.aliases[alias]
        msg.send "Ok, the alias '#{alias}' is forgotten."
      else
        msg.send "Sorry, I don't know the alias '#{alias}'."
    .catch (e) ->
      msg.send e.message or e

  #   hubot phad feed <project> to <room>
  robot.respond /phad feeds? (.+) to (.+)$/, (msg) ->
    project = msg.match[1]
    room = msg.match[2]
    phab.getPermission(msg.envelope.user, 'phadmin')
    .then ->
      phab.getProject(project)
    .then (proj) ->
      if proj.data.parent?
        fullname = "#{proj.data.parent}/#{proj.data.name}"
      else
        fullname = proj.data.name
      phab.data.projects[fullname].feeds ?= [ ]
      if room in phab.data.projects[fullname].feeds
        msg.send "The feed from '#{fullname}' to '#{room}' already exist."
      else
        phab.data.projects[fullname].feeds.push room
        msg.send "Ok, '#{fullname}' is now feeding '#{room}'."
    .catch (e) ->
      msg.send e.message or e

  #   hubot phad feedall to <room>
  robot.respond /phad feedall to (.+)$/, (msg) ->
    room = msg.match[1]
    phab.getPermission(msg.envelope.user, 'phadmin')
    .then ->
      phab.getProject('*')
    .then (proj) ->
      phab.data.projects['*'].feeds ?= [ ]
      if room in phab.data.projects['*'].feeds
        msg.send "The catchall feed to '#{room}' already exist."
      else
        phab.data.projects['*'].feeds.push room
        msg.send "Ok, all feeds will be announced on '#{room}'."
    .catch (e) ->
      msg.send e.message or e

  #   hubot phad remove <project> from <room>
  robot.respond /phad remove (.+) from (.+)$/, (msg) ->
    project = msg.match[1]
    room = msg.match[2]
    phab.getPermission(msg.envelope.user, 'phadmin')
    .then ->
      phab.getProject(project)
    .then (proj) ->
      if proj.data.parent?
        fullname = "#{proj.data.parent}/#{proj.data.name}"
      else
        fullname = proj.data.name
      phab.data.projects[fullname].feeds ?= [ ]
      if room in phab.data.projects[fullname].feeds
        idx = phab.data.projects[fullname].feeds.indexOf room
        phab.data.projects[fullname].feeds.splice(idx, 1)
        msg.send "Ok, The feed from '#{fullname}' to '#{room}' was removed."
      else
        msg.send "Sorry, '#{fullname}' is not feeding '#{room}'."
    .catch (e) ->
      msg.send e.message or e

  #   hubot phad removeall from <room>
  robot.respond /phad removeall from (.+)$/, (msg) ->
    room = msg.match[1]
    phab.getPermission(msg.envelope.user, 'phadmin')
    .then ->
      phab.getProject('*')
    .then (proj) ->
      proj.data.feeds ?= [ ]
      phab.data.projects['*'].feeds ?= [ ]
      if room in phab.data.projects['*'].feeds
        idx = phab.data.projects['*'].feeds.indexOf room
        phab.data.projects['*'].feeds.splice(idx, 1)
        msg.send "Ok, The catchall feed to '#{room}' was removed."
      else
        msg.send "Sorry, the catchall feed for '#{room}' doesn't exist."
    .catch (e) ->
      msg.send e.message or e

  #   hubot phad columns <project>
  robot.respond /phad columns (.+)$/, (msg) ->
    project = msg.match[1]
    phab.getPermission(msg.envelope.user, 'phadmin')
    .then ->
      phab.getProject(project)
    .then (payload) ->
      if payload.data.columns? and Object.keys(payload.data.columns).length > 0
        msg.send "Columns for #{project}: #{Object.keys(payload.data.columns).join(', ')}"
      else
        msg.send "The project #{project} has no columns."
    .catch (e) ->
      msg.send e.message or e
