require 'manageiq/api/common/open_api/generator'
class OpenapiGenerator < ManageIQ::API::Common::OpenApi::Generator
  def build_paths
    applicable_rails_routes.each_with_object({}) do |route, expected_paths|
      without_format = route.path.split("(.:format)").first
      sub_path = without_format.split(base_path).last.sub(/:[_a-z]*id/, "{id}")
      klass_name = route.controller.split("/").last.camelize.singularize
      verb = route.verb.downcase
      primary_collection = sub_path.split("/")[1].camelize.singularize

      expected_paths[sub_path] ||= {}
      expected_paths[sub_path][verb] =
        case route.action
          when "index"   then openapi_list_description(klass_name, primary_collection)
          when "show"    then openapi_show_description(klass_name)
          when "destroy" then openapi_destroy_description(klass_name)
          when "create"  then openapi_create_description(klass_name)
          when "update"  then openapi_update_description(klass_name, verb)
          else
            if verb == "get" && GENERATOR_IMAGE_MEDIA_TYPE_DEFINITIONS.include?(route.action.camelize)
              openapi_show_image_media_type_description(route.action.camelize, primary_collection)
            end
        end

      unless expected_paths[sub_path][verb]
        # If it's not generic action but a custom method like e.g. `post "order", :to => "service_plans#order"`, we will
        # try to take existing schema, because the description, summary, etc. are likely to be custom.
        expected_paths[sub_path][verb] =
          case verb
          when "post"
            if sub_path == "/graphql" && route.action == "query"
              schemas["GraphQLResponse"] = ::ManageIQ::API::Common::GraphQL.openapi_graphql_response
              ::ManageIQ::API::Common::GraphQL.openapi_graphql_description
            else
              openapi_contents.dig("paths", sub_path, verb) || openapi_create_description(klass_name)
            end
          when "get"
            openapi_contents.dig("paths", sub_path, verb) || openapi_show_description(klass_name)
          else
            openapi_contents.dig("paths", sub_path, verb)
          end
      end
    end
  end

  def openapi_schema(klass_name)
    {
      "type"       => "object",
      "properties" => openapi_schema_properties(klass_name),
    }
  end

  def openapi_schema_properties(klass_name)
    model = klass_name.constantize
    model.columns_hash.map do |key, value|
      next if GENERATOR_BLACKLIST_ATTRIBUTES.include?(key.to_sym)

      [key, openapi_schema_properties_value(klass_name, model, key, value)]
    end.compact.sort.to_h
  end

  def openapi_show_image_media_type_description(klass_name, primary_collection)
    primary_collection = nil if primary_collection == klass_name
    {
      "summary"     => "Show an existing #{primary_collection} #{klass_name}",
      "operationId" => "show#{primary_collection}#{klass_name}",
      "description" => "Returns a #{primary_collection} #{klass_name}",
      "parameters"  => [{ "$ref" => build_parameter("ID") }],
      "responses"   => {
        "200" => {
          "description" => "#{primary_collection} #{klass_name}",
          "content"     => {
            "image/*" => {
              "schema" => {
                "type"   => "string",
                "format" => "binary"
              }
            }
          }
        },
        "404" => {"description" => "Not found"}
      }
    }
  end

  def run(graphql)
    parameters["QueryOffset"] = {
      "in"          => "query",
      "name"        => "offset",
      "description" => "The number of items to skip before starting to collect the result set.",
      "required"    => false,
      "schema"      => {
        "type"    => "integer",
        "minimum" => 0,
        "default" => 0
      }
    }

    parameters["QueryLimit"] = {
      "in"          => "query",
      "name"        => "limit",
      "description" => "The numbers of items to return per page.",
      "required"    => false,
      "schema"      => {
        "type"    => "integer",
        "minimum" => 1,
        "maximum" => 1000,
        "default" => 100
      }
    }

    parameters["QueryFilter"] = {
      "in"          => "query",
      "name"        => "filter",
      "description" => "Filter for querying collections.",
      "required"    => false,
      "style"       => "deepObject",
      "explode"     => true,
      "schema"      => {
        "type" => "object"
      }
    }

    schemas["CollectionLinks"] = {
      "type" => "object",
      "properties" => {
        "first" => {
          "type" => "string"
        },
        "last"  => {
          "type" => "string"
        },
        "prev"  => {
          "type" => "string"
        },
        "next"  => {
          "type" => "string"
        }
      }
    }

    schemas["CollectionMetadata"] = {
      "type"       => "object",
      "properties" => {
        "count"  => {
          "type" => "integer"
        },
        "offset" => {
          "type" => "integer"
        },
        "limit"  => {
          "type" => "integer"
        }
      }
    }

    schemas["OrderParametersServiceOffering"] = {
      "type"                 => "object",
      "additionalProperties" => false,
      "properties"           => {
        "service_parameters"          => {
          "type"        => "object",
          "description" => "JSON object with provisioning parameters"
        },
        "provider_control_parameters" => {
          "type"        => "object",
          "description" => "The provider specific parameters needed to provision this service. This might include namespaces, special keys"
        },
        "service_plan_id" => {
          "$ref" => "##{SCHEMAS_PATH}/ID"
        }
      }
    }

    schemas["OrderParametersServicePlan"] = {
      "type"                 => "object",
      "additionalProperties" => false,
      "properties"           => {
        "service_parameters"          => {
          "type"        => "object",
          "description" => "JSON object with provisioning parameters"
        },
        "provider_control_parameters" => {
          "type"        => "object",
          "description" => "The provider specific parameters needed to provision this service. This might include namespaces, special keys"
        },
      }
    }

    schemas["Tenant"] = {
      "type"       => "object",
      "properties" => {
        "id"              => {"$ref" => "##{SCHEMAS_PATH}/ID"},
        "name"            => {"type" => "string", "readOnly" => true, "example" => "Sample Tenant"},
        "description"     => {"type" => "string", "readOnly" => true, "example" => "Description of the Tenant"},
        "external_tenant" => {"type" => "string", "readOnly" => true, "example" => "External tenant identifier"}
      }
    }

    schemas["Tagging"] = {
      "type"       => "object",
      "properties" => {
        "tag_id" => {"$ref" => "##{SCHEMAS_PATH}/ID"},
        "name"   => {"type" => "string", "readOnly" => true, "example" => "architecture"},
        "value"  => {"type" => "string", "readOnly" => true, "example" => "x86_64"}
      }
    }

    schemas["ID"] = {
      "type" => "string", "description" => "ID of the resource", "pattern" => "^\\d+$", "readOnly" => true
    }

    new_content = openapi_contents
    new_content["paths"] = build_paths.sort.to_h
    new_content["components"] ||= {}
    new_content["components"]["schemas"]    = schemas.sort.each_with_object({})    { |(name, val), h| h[name] = val || openapi_contents["components"]["schemas"][name]    || {} }
    new_content["components"]["parameters"] = parameters.sort.each_with_object({}) { |(name, val), h| h[name] = val || openapi_contents["components"]["parameters"][name] || {} }
    File.write(openapi_file, JSON.pretty_generate(new_content) + "\n")
    ManageIQ::API::Common::GraphQL::Generator.generate(api_version, new_content) if graphql
  end
end

GENERATOR_BLACKLIST_ATTRIBUTES           = [
  :resource_timestamp, :resource_timestamps, :resource_timestamps_max, :tenant_id
].to_set.freeze
GENERATOR_READ_ONLY_DEFINITIONS = [
  'Container', 'ContainerGroup', 'ContainerImage', 'ContainerNode', 'ContainerProject', 'ContainerTemplate', 'Flavor',
  'OrchestrationStack', 'ServiceInstance', 'ServiceOffering', 'ServiceOfferingIcon', 'ServicePlan', 'Tag', 'Tagging',
  'Vm', 'Volume', 'VolumeAttachment', 'VolumeType', 'ContainerResourceQuota'
].to_set.freeze
GENERATOR_READ_ONLY_ATTRIBUTES = [
  :created_at, :updated_at, :archived_at, :last_seen_at
].to_set.freeze
GENERATOR_IMAGE_MEDIA_TYPE_DEFINITIONS = [
  'IconData'
].to_set.freeze

namespace :openapi do
  desc "Generate the openapi.json contents"
  task :generate, [:graphql] => [:environment] do |_task, args|
    graphql = args[:graphql] == "graphql"
    OpenapiGenerator.new.run(graphql)
  end
end
