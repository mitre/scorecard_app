require 'yaml'
require 'sinatra'
require 'fhir_client'
require 'rest-client'
require 'fhir_scorecard'

enable :sessions
set :session_secret, SecureRandom.uuid

puts "Loading terminology..."
FHIR::Terminology.load_terminology
puts "Finished loading terminology."

# Load the client_ids and scopes from a configuration file
CONFIGURATION = YAML.load(File.open('config.yml','r:UTF-8',&:read))

# Given a URL, choose a client_id to use
def get_client_id(url)
  return nil unless url
  CONFIGURATION['client_id'].each do |key,value|
    return value if url.include?(key)
  end
  nil
end

# Given a URL, choose the OAuth2 scopes to request
def get_scopes(url)
  return nil unless url
  CONFIGURATION['scopes'].each do |key,value|
    return value if url.include?(key)
  end
  nil
end

def open_html
  '<html>
    <head>
      <title>ScorecardApp</title>
      <link rel="stylesheet" href="jquery-ui-1.12.1.custom/jquery-ui.css">
      <link rel="stylesheet" href="http://yui.yahooapis.com/pure/0.6.0/pure-min.css">
      <style>
        table {
            border-collapse: collapse;
        }
        table, td, th {
            border: 1px solid black;
        }
      </style>
      <script src="https://code.jquery.com/jquery-1.12.4.js"></script>
      <script src="jquery-ui-1.12.1.custom/jquery-ui.js"></script>
      <script>
        $( function() {
          $( "#accordion" ).accordion({
            collapsible: true,
            heightStyle: "content",
            active: 3
          });
        } );
      </script>
    </head>
  <body><h1>ScorecardApp</h1><div id="accordion">'
end

def close_html
  '</div></body></html>'
end

# Extract the Authorization and Token URLs
# from the FHIR Conformance/CapabilityStatement
def get_auth_info(issuer)
  return {} unless issuer
  client = FHIR::Client.new(issuer)
  client.default_json
  client.get_oauth2_metadata_from_conformance
end

# Output a Hash as an HTML Table
def echo_hash(name,hash,headers=[])
  content = "<h3>#{name}</h3><table class=\"pure-table\">"
  if !headers.empty?
    content += "<thead><tr>"
    headers.each do |title|
      content += "<th>#{title}</th>"
    end
    content += "</tr></thead>"
  end
  content += "<tbody>"
  alt = true
  hash.each do |key,value|
    if alt
      content += "<tr class=\"pure-table-odd\"><td>#{key}</td>"
    else
      content += "<tr><td>#{key}</td>"
    end
    alt = !alt
    if value.is_a?(Hash)
      value.each do |sk,sv|
        content += "<td>#{sv}</td>"
      end
      content += "</tr>"
    else
      content += "<td>#{value}</td></tr>"
    end
  end
  content += '</tbody></table>'
  content
end

# Root: redirect to /index
get '/' do
  status, headers, body = call! env.merge("PATH_INFO" => '/index')
end

# The index  displays the available endpoints
get '/index' do
  bullets = {
    '/index' => 'this page',
    '/app' => 'the app (also the redirect_uri after authz)',
    '/launch' => 'the launch url'
  }
  body "#{open_html}#{echo_hash('End Points',bullets)}#{close_html}"
end

# This is the primary endpoint of the app and the OAuth2 redirect URL
get '/app' do
  if params['error']
    if params['error_uri']
      redirect params['error_uri']
    else
      body "#{open_html}#{echo_hash('Invalid Launch!',params)}#{close_html}"
    end
  elsif params['state'] && params['state'] != session[:state]
    body "#{open_html}#{echo_hash('Invalid Launch State!',params)}#{close_html}"
  else
    # Get the OAuth2 token
    puts "App Params: #{params}"

    oauth2_params = {
      'grant_type' => 'authorization_code',
      'code' => params['code'],
      'redirect_uri' => "#{request.base_url}/app",
      'client_id' => session[:client_id]
    }
    puts "Token Params: #{oauth2_params}"
    token_response = RestClient.post(session[:token_url], oauth2_params) #, { 'content-type' => 'application/x-www-form-urlencoded' }
    token_response = JSON.parse(token_response.body)
    puts "Token Response: #{token_response}"
    token = token_response['access_token']
    patient_id = token_response['patient']
    scopes = token_response['scope']

    # Configure the FHIR Client
    client = FHIR::Client.new(session[:fhir_url])
    client.set_bearer_token(token)
    client.default_format = 'application/json+fhir'

    # Get the patient demographics
    patient = client.read(FHIR::Patient, patient_id).resource
    puts "Patient: #{patient.id} #{patient.name}"
    patient_details = patient.to_hash.keep_if{|k,v| ['id','name','gender','birthDate'].include?(k)}

    # Get the patient's conditions
    condition_reply = client.search(FHIR::Condition, search: { parameters: { 'patient' => patient_id, 'clinicalstatus' => 'active' } })
    puts "Conditions: #{condition_reply.resource.entry.length}"

    # Get the patient's medications
    medication_reply = client.search(FHIR::MedicationOrder, search: { parameters: { 'patient' => patient_id, 'status' => 'active' } })
    puts "Medications: #{medication_reply.resource.entry.length}"

    # Assemble the patient record
    record = FHIR::Bundle.new
    record.entry << bundle_entry(patient)
    condition_reply.resource.each do |resource|
      record.entry << bundle_entry(resource)
    end
    medication_reply.resource.each do |resource|
      record.entry << bundle_entry(resource)
    end
    puts "Built the bundle..."

    # Score the bundle
    scorecard = FHIR::Scorecard.new
    scorecard_report = scorecard.score(record.to_json)

    response_body = open_html
    response_body += echo_hash('params',params)
    response_body += echo_hash('token response',token_response)
    response_body += echo_hash('patient',patient_details)
    response_body += echo_hash('scorecard',scorecard_report,['rubric','points','description'])
    response_body += close_html
    body response_body
  end
end

# Helper method to wrap a resource in a Bundle.entry
def bundle_entry(resource)
  entry = FHIR::Bundle::Entry.new
  entry.resource = resource
  entry
end

# This is the launch URI that redirects to an Authorization server
get '/launch' do
  client_id = get_client_id(params['iss'])
  auth_info = get_auth_info(params['iss'])
  session[:client_id] = client_id
  session[:fhir_url] = params['iss']
  session[:authorize_url] = auth_info[:authorize_url]
  session[:token_url] = auth_info[:token_url]
  puts "Launch Client ID: #{client_id}\nLaunch Auth Info: #{auth_info}\nLaunch Redirect: #{request.base_url}/app"
  session[:state] = SecureRandom.uuid
  oauth2_params = {
    'response_type' => 'code',
    'client_id' => client_id,
    'redirect_uri' => "#{request.base_url}/app",
    'scope' => get_scopes(params['iss']),
    'launch' => params['launch'],
    'state' => session[:state],
    'aud' => params['iss']
  }
  oauth2_auth_query = "#{session[:authorize_url]}?"
  oauth2_params.each do |key,value|
    oauth2_auth_query += "#{key}=#{CGI.escape(value)}&"
  end
  puts "Launch Authz Query: #{oauth2_auth_query[0..-2]}"
  content = "#{open_html}#{echo_hash('params',params)}#{echo_hash('OAuth2 Metadata',auth_info)}#{close_html}"
  redirect oauth2_auth_query[0..-2], content
end
