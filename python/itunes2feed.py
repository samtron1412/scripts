#!/usr/bin/python3

#######################################################
#
# Get the feed URL from the iTunes link
#
# Usage: $ python3 itunes2feed.py <iTunes-link>
#   An example of iTunes link:
#   https://itunes.apple.com/us/podcast/nasa-in-silicon-valley/id1137247670
#
#######################################################

import sys,urllib.parse,urllib.request
import json

#url for itunes podcast page
base_itunes_url = "https://itunes.apple.com/lookup"
param = {
            "id": None, #we'll need to find this
        }

#initial subscribe/general page
url = sys.argv[1]
url_info = urllib.parse.urlparse(url)

#now extract podcast id from url
pod_id = ''.join(list(url_info[2].split('/')[-1])[2:])

#insert id into parameters
param["id"] = pod_id

#create new url with podcast id
p = urllib.parse.urlencode(param)
itunes_url = '?'.join([base_itunes_url,p])

#open the url
a = urllib.request.urlopen(itunes_url).read()

#parse the result to get the RSS link
j = json.loads(a.decode())
print(j['results'][0]['feedUrl'])
