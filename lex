#!/usr/bin/env python3

from sys import argv, stdin
from json import load, dump, dumps
from json.decoder import JSONDecodeError
from os import path, environ, remove
from hashlib import md5
from tempfile import NamedTemporaryFile
from subprocess import run

from requests import request


CACHE = "cache.json"
MAXIMUM = 2 ** 8 - 1
ENDPOINT = "https://www.duolingo.com/2017-06-30/users/"
LEXEMES = "lexemes.json"


def get(identity, nonce, _stdin):
  endpoint = ENDPOINT + identity

  lines = iter(_stdin)
  next(lines)
  headers = dict(map(lambda header: header.strip().split(": ", 1), lines))
  del headers['Content-Length']

  with Cache(CACHE, headers) as cache:
    course = cache\
      .get(endpoint, params = dict(fields = 'currentCourse', _ = nonce))\
        ['currentCourse']
    tracking = course['trackingProperties']
    sections = list()
    encountered = set()
    for section in course['pathSectioned'][:-1]:
      units = list()
      for unitAPI in section['units']:
        unit = dict()
        for lexeme in cache.post(
          "/".join([
            endpoint,
            'courses',
            tracking['learning_language'],
            tracking['ui_language'],
            'learned-lexemes'
          ]),
          json = dict(progressedSkills = [dict(
            finishedLevels = MAXIMUM,
            finishedSessions = MAXIMUM,
            skillId = dict(id = next(filter(
              lambda skill: skill,
              map(
                lambda level: level['pathLevelMetadata'].get('skillId'),
                unitAPI['levels']
              )
            )))
          )])
        )['learnedLexemes']:
          text = lexeme['text']
          if text not in encountered:
            unit[text] = lexeme['translations']
            encountered.add(text)
        units.append(unit)
      sections.append(units)
    cache.set('sections', sections)

def lex(sectionIndex, unitIndex):
  lexemes = loadOrDict(LEXEMES)
  unitIn = dict()
  with Cache(CACHE) as cache:
    for word, translations \
      in cache.retrieve('sections')[sectionIndex - 1][unitIndex - 1].items()\
    :
      lexeme = lexemes.get(word, dict(override = None, readings = dict()))
      if 'override' not in lexeme: lexeme['override'] = None
      lexeme['translations'] = "; ".join(translations)
      unitIn[word] = lexeme
  try:
    with NamedTemporaryFile(suffix = '.json', delete = False) as file:
      name = file.name
    original = dumps(unitIn, ensure_ascii = False, indent = 2)
    write(name, original)
    valid = False
    while not valid:
      run([environ['EDITOR'], name])
      try:
        with open(name) as file:
          unitOut = load(file)
        valid = True
      except JSONDecodeError as exception:
        print(exception)
        if input("Revert to original (y/N)?").lower() == 'y':
          write(name, original)
  finally:
    remove(name)
  for word, details in unitOut.items():
    _readings = details['readings']
    override = details['override']
    if len(_readings): lexemes[word] = dict(
      **dict(readings = _readings),
      **dict(override = override) if override else dict()
    )
    else:
      if details['override']: raise Exception
      if word in lexemes: lexemes.pop(word)
  with open(LEXEMES, "w") as file:
    dump(lexemes, file, ensure_ascii = False)


class Cache:
  def __init__(self, _path, headers = None):
    self.path = _path
    self.headers = headers

  def __enter__(self):
    self.cache = loadOrDict(self.path)
    return self

  def __exit__(self, *extra):
    if self.headers is not None:
      with open(self.path, "w") as file:
        dump(self.cache, file)

  def request(self, method, URL, **keywords):
    hashSum = md5(
      dumps(dict(method = method, URL = URL, **keywords), sort_keys = True)
        .encode()
    ).hexdigest()
    if hashSum in self.cache:
      response = self.cache[hashSum]
    else: self.cache[hashSum] \
      = request(method, URL, headers = self.headers, **keywords).json()
    return response

  def get(self, URL, **keywords): return self.request('GET', URL, **keywords)
  def post(self, URL, **keywords): return self.request('POST', URL, **keywords)

  def retrieve(self, key): return self.cache[key]
  def set(self, key, value): self.cache[key] = value


def write(_path, contents):
  with open(_path, "w") as file: file.write(contents)

def loadOrDict(_path):
  if path.exists(_path):
    with open(_path) as file: contents = load(file)
  else: contents = dict()
  return contents


if __name__ == '__main__':
  dict(
    get = lambda: get(*argv[2:], stdin),
    lex = lambda: lex(*list(map(int, argv[2:])))
  )[argv[1]]()
