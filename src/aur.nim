import
  json, lists, options, re, sequtils, sets, strutils, sugar, tables,
  package, utils,
  "wrapper/curl"

type
  AurComment* = tuple[
    author: string,
    date: string,
    text: string
  ]

const
  aurUrl* = "https://aur.archlinux.org/"

template gitUrl(base: string): string =
  aurUrl & base & ".git"

proc parseRpcPackageInfo(obj: JsonNode, repo: string): Option[RpcPackageInfo] =
  template optInt64(i: int64): Option[int64] =
    if i > 0: some(i) else: none(int64)

  let base = obj["PackageBase"].getStr
  let name = obj["Name"].getStr
  let version = obj["Version"].getStr
  let descriptionEmpty = obj["Description"].getStr
  let description = if descriptionEmpty.len > 0: some(descriptionEmpty) else: none(string)
  let maintainerEmpty = obj["Maintainer"].getStr
  let maintainer = if maintainerEmpty.len > 0: some(maintainerEmpty) else: none(string)
  let firstSubmitted = obj["FirstSubmitted"].getBiggestInt(0).optInt64
  let lastModified = obj["LastModified"].getBiggestInt(0).optInt64
  let outOfDate = obj["OutOfDate"].getBiggestInt(0).optInt64
  let votes = (int) obj["NumVotes"].getBiggestInt(0)
  let popularity = obj["Popularity"].getFloat(0)

  if base.len > 0 and name.len > 0:
    some((repo, base, name, version, description, maintainer, firstSubmitted, lastModified,
      outOfDate, votes, popularity, gitUrl(base), none(string)))
  else:
    none(RpcPackageInfo)

template withAur*(body: untyped): untyped =
  withCurlGlobal():
    body

proc obtainPkgBaseSrcInfo(base: string, useTimeout: bool): (string, Option[string]) =
  try:
    withAur():
      withCurl(instance):
        let url = aurUrl & "cgit/aur.git/plain/.SRCINFO?h=" &
          instance.escape(base)
        (performString(url, useTimeout), none(string))
  except CurlError:
    ("", some(getCurrentException().msg))

proc getRpcPackageInfos*(pkgs: seq[string], repo: string, useTimeout: bool):
  (seq[RpcPackageInfo], Option[string]) =
  let dpkgs = pkgs.deduplicate
  if dpkgs.len == 0:
    (@[], none(string))
  else:
    const maxCount = 100
    let distributed = dpkgs.distribute((dpkgs.len + maxCount - 1) /% maxCount)
    withAur():
      try:
        let responses = distributed.map(pkgs => (block:
          withCurl(instance):
            let url = aurUrl & "rpc/?v=5&type=info&arg[]=" & @pkgs
              .map(u => instance.escape(u))
              .foldl(a & "&arg[]=" & b)
            performString(url, useTimeout)))

        when NimVersion >= "1.2":
          let table = collect(initTable):
            for z in responses:
              for y in parseJson(z)["results"]:
                for x in parseRpcPackageInfo(y,repo):
                  {x.name:x}
          ((block:collect(newSeq):
            for p in pkgs:
              for x in table.opt(p):
                x
          ),none(string))
        else:
          let table = lc[(x.name, x) | (z <- responses, y <- parseJson(z)["results"],
            x <- parseRpcPackageInfo(y, repo)), (string, RpcPackageInfo)].toTable
          (lc[x | (p <- pkgs, x <- table.opt(p)), RpcPackageInfo], none(string))
      except CurlError:
        (@[], some(getCurrentException().msg))
      except JsonParsingError:
        (@[], some(tr"failed to parse server response"))

proc getAurPackageInfos*(pkgs: seq[string], repo: string, arch: string, useTimeout: bool):
  (seq[PackageInfo], seq[PackageInfo], seq[string]) =
  if pkgs.len == 0:
    (@[], @[], @[])
  else:
    withAur():
      let (rpcInfos, error) = getRpcPackageInfos(pkgs, repo, useTimeout)

      if error.isSome:
        (@[], @[], @[error.unsafeGet])
      else:
        type
          ParseResult = tuple[
            infos: seq[PackageInfo],
            error: Option[string]
          ]

        when NimVersion >= "1.2":
          let deduplicated = deduplicate:
            collect(newSeq):
              for x in rpcInfos:
                x.base
        else:
          let deduplicated = lc[x.base | (x <- rpcInfos), string].deduplicate

        proc obtainAndParse(base: string, index: int): ParseResult =
          let (srcInfo, operror) = obtainPkgBaseSrcInfo(base, useTimeout)

          if operror.isSome:
            (@[], operror)
          else:
            let pkgInfos = parseSrcInfo(repo, srcInfo, arch,
              gitUrl(base), none(string), rpcInfos)
            (pkgInfos, none(string))

        let parsed = deduplicated.foldl(a & obtainAndParse(b, a.len), newSeq[ParseResult]())
        when NimVersion >= "1.2":
          let infos = collect(newSeq):
            for y in parsed:
              for x in y.infos:
                x
          let errors = collect(newSeq):
            for y in parsed:
              for x in y.error:
                x
        else:
          let infos = lc[x | (y <- parsed, x <- y.infos), PackageInfo]
          let errors = lc[x | (y <- parsed, x <- y.error), string]

        let table = infos.map(i => (i.rpc.name, i)).toTable
        when NimVersion >= "1.2":
          let pkgInfos = collect(newSeq):
            for p in pkgs:
              for x in table.opt(p):
                x
        else:
          let pkgInfos = lc[x | (p <- pkgs, x <- table.opt(p)), PackageInfo]

        let names = rpcInfos.map(i => i.name).toHashSet
        let additionalPkgInfos = infos.filter(i => not (i.rpc.name in names))

        (pkgInfos, additionalPkgInfos, errors)

proc findAurPackages*(query: seq[string], repo: string, useTimeout: bool):
  (seq[RpcPackageInfo], Option[string]) =
  if query.len == 0 or query[0].len <= 2:
    (@[], none(string))
  else:
    withAur():
      try:
        withCurl(instance):
          let url = aurUrl & "rpc/?v=5&type=search&by=name-desc&arg=" &
            instance.escape(query[0])

          let response = performString(url, useTimeout)
          let results = parseJson(response)["results"]
          when NimVersion >= "1.2":
            let rpcInfos = collect(newSeq):
              for y in results:
                for x in parseRpcPackageInfo(y,repo):
                  x
          else:
            let rpcInfos = lc[x | (y <- results, x <- parseRpcPackageInfo(y, repo)), RpcPackageInfo]

          let filteredRpcInfos = if query.len > 1: (block:
              let queryLow = query[1 .. ^1].map(q => q.toLowerAscii)
              rpcInfos.filter(i => queryLow.map(q => i.name.toLowerAscii.contains(q) or
                i.description.map(d => d.toLowerAscii.contains(q)).get(false)).foldl(a and b)))
            else:
              rpcInfos

          (filteredRpcInfos, none(string))
      except CurlError:
        (@[], some(getCurrentException().msg))

proc downloadAurComments*(base: string): (seq[AurComment], Option[string]) =
  let (content, error) = withAur():
    try:
      withCurl(instance):
        let url = aurUrl & "pkgbase/" & base & "/?comments=all"
        (performString(url, true), none(string))
    except CurlError:
      ("", some(getCurrentException().msg))

  if error.isSome:
    (@[], error)
  else:
    let commentRe = re("<h4\\ id=\"comment-\\d+\">\\n\\s+(.*)?\\ commented\\ on\\ " &
      "(.*)\\n(?:.*\\n)*?\\s+</h4>\\n\\t\\t<div\\ id=\"comment-\\d+-content\"\\ " &
      "class=\"article-content\">((?:\\n.*)*?)\\n\\t\\t</div>")

    proc transformComment(comment: string): string =
      comment
        # line breaks can leave a space
        .replace("\n", " ")
        # force line break
        .replace("<br />", "\n")
        # paragraphs look like 2 line breaks
        .replace("<p>", "\n\n")
        .replace("</p>", "\n\n")
        # remove tags
        .replace(re"<.*?>", "")
        # multiple spaces become 1 spage
        .replace(re"\ {2,}", " ")
        # strip lines
        .strip.split("\n").map(s => s.strip).foldl(a & "\n" & b).strip
        # don't allow more than 2 line breaks
        .replace(re"\n{2,}", "\n\n")
        # replace mnemonics
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&amp;", "&")

    proc findAllMatches(start: int, found: List[AurComment]): List[AurComment] =
      var matches: array[3, string]
      let index = content.find(commentRe, matches, start)
      if index >= 0:
        findAllMatches(index + 1, (matches[0].strip, matches[1].strip,
          transformComment(matches[2])) ^& found)
      else:
        found

    (toSeq(findAllMatches(0, nil).reversed.items), none(string))
