#!/usr/bin/env python3

from sys import argv, stdin
from json import load, dump, dumps, loads
from json.decoder import JSONDecodeError
from os import path, environ, remove
from hashlib import md5
from tempfile import NamedTemporaryFile
from subprocess import Popen, PIPE, run
from time import time
from random import choice
from collections import defaultdict

from requests import request


CACHE = "cache.json"
MAXIMUM = 2 ** 8 - 1
ENDPOINT = "https://www.duolingo.com/2017-06-30/users/"
LEXEMES = "lexemes.json"
IDENTIFIER_APPLICATION = "com.mindtwisted.kanjistudy"
APPLICATION = "application.db"
CONTENT = "content.db"
PATH = f"/data/data/{IDENTIFIER_APPLICATION}/databases/"
READINGS = ("kun", "on")


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
    writeFile(name, original)
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
          writeFile(name, original)
  finally:
    remove(name)
  for word, details in unitOut.items():
    readingsDetails = details['readings']
    override = details['override']
    if len(readingsDetails): lexemes[word] = dict(
      **dict(readings = readingsDetails),
      **dict(override = override) if override else dict()
    )
    else:
      if details['override']: raise Exception
      if word in lexemes: lexemes.pop(word)
  with open(LEXEMES, "w") as file:
    dump(lexemes, file, ensure_ascii = False)

def write(sectionUpTo, unitUpTo):
  user \
    = "u0_a" \
      + str(
        int(next(filter(
          lambda line: 'appId' in line,
          run(
            ('adb', 'shell', 'dumpsys', 'package', IDENTIFIER_APPLICATION),
            capture_output = True
          ).stdout.decode().split("\n")
        )).split("=")[1])
        - 10000
      )

  application = Database(user, PATH + APPLICATION)
  application.execute("""
    delete from groupings;
    delete from groups where grouping_id is not null;
    delete from groups_link where group_id not in (select id from groups);
    delete from kanji_override;
  """)

  with Cache(CACHE) as cache:
    sections = cache.retrieve('sections')
  content = Database(user, PATH + CONTENT)
  kanjiDict = {
    chr(kanji['code']):
      kanji for kanji in content.execute("select * from kanji;")
  }
  kanjiKeys = set(kanjiDict.keys())
  with open(LEXEMES) as file:
    lexemes = load(file)

  counts = list(map(len, sections[:int(sectionUpTo) - 1])) + [int(unitUpTo)]
  cumulative = 1
  readings \
    = defaultdict(lambda: {typeReading: dict() for typeReading in READINGS})
  markings = {ord(character): None for character in ("*", "!")}
  now = int(time() * 1000)
  for section, _unitUpTo in enumerate(counts):
    grouping = application.insertWithIdentity(
      "insert into groupings "
      + SQLmap(
        type = 0,
        name = f"Section {section + 1}",
        position = section,
        created_at = now
      )
      + ";"
    )
    for unit in range(_unitUpTo):
      group = application.insertWithIdentity(
        "insert into groups "
        + SQLmap(
          level = 0,
          level_mode = 0,
          type = 0,
          name = f"Unit {cumulative}",
          position = unit,
          last_studied_at = 0,
          grouping_id = grouping
        )
        + ";"
      )
      kanjiUnit = []
      with Queue(application) as queueApplication:
        for _lexeme in sections[section][unit].keys():
          if details := lexemes.get(_lexeme):
            lexeme = details.get('override', _lexeme)
            readingsKanji = details['readings']
            used \
              = set(filter(lambda character: character in kanjiKeys, lexeme))
            assert used == set(readingsKanji.keys())
            for kanji in used:
              if kanji not in readings:
                kanjiUnit.append(kanji)
                for typeReading in READINGS:
                  readingsType = kanjiDict[kanji][typeReading + "_reading"]
                  if readingsType:
                    for readingsDetails in readingsType.split(","):
                      reading, *importance = readingsDetails.split("!")
                      readings[kanji][typeReading]\
                        [reading[reading[0] == "*":]] \
                          = dict(important = bool(importance), used = False)
                queueApplication(
                  "insert into groups_link "
                  + SQLmap(
                    group_id = group,
                    code = ord(kanji),
                    sequence = now,
                    date_added = now
                  )
                  + ";"
                )
              readingCustom = readingsKanji[kanji]
              typeReading = READINGS[int(readingCustom[0] >= 'ァ')]
              readingsType = readings[kanji][typeReading]
              readingsType[readingCustom]['used'] = True
        chosen = kanjiDict[choice(kanjiUnit)]
        queueApplication(f"""
          update groups
            set
              display_code = {chosen['code']},
              display_stroke_paths = "{chosen['stroke_paths']}"
            where id = {group};
        """)
      cumulative += 1
  with Queue(content) as queueContent:
    for kanji, readingsKanji in readings.items(): queueContent(
      "update kanji set "
      + ", ".join(
        f"custom_{typeReading}_reading = "
        + (
          (
            "\""
            + ",".join(
              ("" if details['used'] else "*")
              + reading
              + ("!" if details['important'] else "")
                for reading, details in readingsType.items()
            )
            + "\""
          ) if readingsType else "null"
        ) for typeReading, readingsType in readingsKanji.items()
      )
      + f" where code = {ord(kanji)};"
    )


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

class Database:
  def __init__(self, user, _path):
    self.command = ('adb', 'shell', 'su', user, "-c", "sqlite3 -json " + _path)

  def execute(self, query):
    process = Popen(self.command, text = True, stdin = PIPE, stdout = PIPE)
    output = process.communicate(query)[0]
    if output:
      result = loads(output)
      assert not process.wait()
      return result

  def insertWithIdentity(self, query): return \
    self.execute("begin; " + query + "select last_insert_rowid(); commit;")\
      [0]['last_insert_rowid()']

class Queue:
  def __init__(self, database):
    self.database = database
    self.queue = []

  def __enter__(self):
    return self

  def __call__(self, query):
    self.queue.append(query)

  def __exit__(self, *extra):
    self.database.execute("\n".join(self.queue))


def writeFile(_path, contents):
  with open(_path, "w") as file: file.write(contents)

def loadOrDict(_path):
  if path.exists(_path):
    with open(_path) as file: contents = load(file)
  else: contents = dict()
  return contents

quote = {ord("\""): Exception}
SQLmap = lambda **keywords: \
  "(" \
    + ", ".join(map(lambda key: key.translate(quote), keywords.keys())) \
  + ") " \
  + "values(" + ", ".join(map(
    lambda value: f"\"{value.translate(quote)}\""
      if type(value) is str else str(value),
    keywords.values()
  )) + ")"


if __name__ == '__main__':
  dict(
    get = lambda: get(*argv[2:], stdin),
    lex = lambda: lex(*list(map(int, argv[2:]))),
    write = lambda: write(*argv[2:])
  )[argv[1]]()
