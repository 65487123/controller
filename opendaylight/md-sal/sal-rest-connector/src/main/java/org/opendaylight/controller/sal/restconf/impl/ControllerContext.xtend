package org.opendaylight.controller.sal.restconf.impl

import com.google.common.collect.BiMap
import com.google.common.collect.FluentIterable
import com.google.common.collect.HashBiMap
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.util.HashMap
import java.util.List
import java.util.Map
import java.util.concurrent.ConcurrentHashMap
import org.opendaylight.controller.sal.core.api.model.SchemaServiceListener
import org.opendaylight.controller.sal.core.api.mount.MountService
import org.opendaylight.controller.sal.rest.impl.RestUtil
import org.opendaylight.controller.sal.rest.impl.RestconfProvider
import org.opendaylight.yangtools.yang.common.QName
import org.opendaylight.yangtools.yang.data.api.InstanceIdentifier
import org.opendaylight.yangtools.yang.data.api.InstanceIdentifier.InstanceIdentifierBuilder
import org.opendaylight.yangtools.yang.data.api.InstanceIdentifier.NodeIdentifier
import org.opendaylight.yangtools.yang.data.api.InstanceIdentifier.NodeIdentifierWithPredicates
import org.opendaylight.yangtools.yang.data.api.InstanceIdentifier.PathArgument
import org.opendaylight.yangtools.yang.data.impl.codec.TypeDefinitionAwareCodec
import org.opendaylight.yangtools.yang.model.api.ChoiceCaseNode
import org.opendaylight.yangtools.yang.model.api.ChoiceNode
import org.opendaylight.yangtools.yang.model.api.ContainerSchemaNode
import org.opendaylight.yangtools.yang.model.api.DataNodeContainer
import org.opendaylight.yangtools.yang.model.api.DataSchemaNode
import org.opendaylight.yangtools.yang.model.api.LeafListSchemaNode
import org.opendaylight.yangtools.yang.model.api.LeafSchemaNode
import org.opendaylight.yangtools.yang.model.api.ListSchemaNode
import org.opendaylight.yangtools.yang.model.api.Module
import org.opendaylight.yangtools.yang.model.api.RpcDefinition
import org.opendaylight.yangtools.yang.model.api.SchemaContext
import org.opendaylight.yangtools.yang.model.api.type.IdentityrefTypeDefinition
import org.slf4j.LoggerFactory

import static com.google.common.base.Preconditions.*
import static javax.ws.rs.core.Response.Status.*
import org.opendaylight.controller.sal.core.api.mount.MountInstance

class ControllerContext implements SchemaServiceListener {
    val static LOG = LoggerFactory.getLogger(ControllerContext)
    val static ControllerContext INSTANCE = new ControllerContext
    val static NULL_VALUE = "null"
    val static MOUNT_MODULE = "yang-ext"
    val static MOUNT_NODE = "mount"
    val static MOUNT = "yang-ext:mount"

    @Property
    var SchemaContext globalSchema;
    
    @Property
    var MountService mountService;

    private val BiMap<URI, String> uriToModuleName = HashBiMap.create();
    private val Map<String, URI> moduleNameToUri = uriToModuleName.inverse();
    private val Map<QName, RpcDefinition> qnameToRpc = new ConcurrentHashMap();

    private new() {
        if (INSTANCE !== null) {
            throw new IllegalStateException("Already instantiated");
        }
    }

    static def getInstance() {
        return INSTANCE
    }

    private def void checkPreconditions() {
        if (globalSchema === null) {
            throw new ResponseException(SERVICE_UNAVAILABLE, RestconfProvider::NOT_INITALIZED_MSG)
        }
    }

    def setSchemas(SchemaContext schemas) {
        onGlobalContextUpdated(schemas)
    }

    public def InstanceIdWithSchemaNode toInstanceIdentifier(String restconfInstance) {
        checkPreconditions
        val pathArgs = restconfInstance.split("/");
        if (pathArgs.empty) {
            return null;
        }
        if (pathArgs.head.empty) {
            pathArgs.remove(0)
        }
        val startModule = pathArgs.head.toModuleName();
        if (startModule === null) {
            throw new ResponseException(BAD_REQUEST, "First node in URI has to be in format \"moduleName:nodeName\"")
        }
        val iiWithSchemaNode = collectPathArguments(InstanceIdentifier.builder(), pathArgs,
            globalSchema.getLatestModule(startModule), null);
        if (iiWithSchemaNode === null) {
            throw new ResponseException(BAD_REQUEST, "URI has bad format")
        }
        return iiWithSchemaNode
    }

    private def getLatestModule(SchemaContext schema, String moduleName) {
        checkArgument(schema !== null);
        checkArgument(moduleName !== null && !moduleName.empty)
        val modules = schema.modules.filter[m|m.name == moduleName]
        return modules.filterLatestModule
    }
    
    private def filterLatestModule(Iterable<Module> modules) {
        var latestModule = modules.head
        for (module : modules) {
            if (module.revision.after(latestModule.revision)) {
                latestModule = module
            }
        }
        return latestModule
    }
    
    def findModuleByName(String moduleName) {
        checkPreconditions
        checkArgument(moduleName !== null && !moduleName.empty)
        return globalSchema.getLatestModule(moduleName)
    }
    
    def findModuleByName(MountInstance mountPoint, String moduleName) {
        checkArgument(moduleName !== null && mountPoint !== null)
        val mountPointSchema = mountPoint.schemaContext;
        return mountPointSchema?.getLatestModule(moduleName);
    }
    
    def findModuleByNamespace(URI namespace) {
        checkPreconditions
        val moduleSchemas = globalSchema.findModuleByNamespace(namespace)
        return moduleSchemas?.filterLatestModule
    }
    
    def findModuleByNamespace(MountInstance mountPoint, URI namespace) {
        checkArgument(namespace !== null && mountPoint !== null)
        val mountPointSchema = mountPoint.schemaContext;
        val moduleSchemas = mountPointSchema?.findModuleByNamespace(namespace)
        return moduleSchemas?.filterLatestModule
    }

    def String toFullRestconfIdentifier(InstanceIdentifier path) {
        checkPreconditions
        val elements = path.path;
        val ret = new StringBuilder();
        val startQName = elements.get(0).nodeType;
        val initialModule = globalSchema.findModuleByNamespaceAndRevision(startQName.namespace, startQName.revision)
        var node = initialModule as DataSchemaNode;
        for (element : elements) {
            node = node.childByQName(element.nodeType);
            ret.append(element.toRestconfIdentifier(node));
        }
        return ret.toString
    }

    private def dispatch CharSequence toRestconfIdentifier(NodeIdentifier argument, DataSchemaNode node) {
        '''/«argument.nodeType.toRestconfIdentifier()»'''
    }

    private def dispatch CharSequence toRestconfIdentifier(NodeIdentifierWithPredicates argument, ListSchemaNode node) {
        val nodeIdentifier = argument.nodeType.toRestconfIdentifier();
        val keyValues = argument.keyValues;
        return '''/«nodeIdentifier»/«FOR key : node.keyDefinition SEPARATOR "/"»«keyValues.get(key).toUriString»«ENDFOR»'''
    }

    private def dispatch CharSequence toRestconfIdentifier(PathArgument argument, DataSchemaNode node) {
        throw new IllegalArgumentException("Conversion of generic path argument is not supported");
    }

    def findModuleNameByNamespace(URI namespace) {
        checkPreconditions
        var module = uriToModuleName.get(namespace)
        if (module === null) {
            val moduleSchemas = globalSchema.findModuleByNamespace(namespace);
            if(moduleSchemas === null) return null
            var latestModule = moduleSchemas.filterLatestModule
            if(latestModule === null) return null
            uriToModuleName.put(namespace, latestModule.name)
            module = latestModule.name;
        }
        return module
    }

    def findNamespaceByModuleName(String module) {
        var namespace = moduleNameToUri.get(module)
        if (namespace === null) {
            var latestModule = globalSchema.getLatestModule(module)
            if(latestModule === null) return null
            namespace = latestModule.namespace
            uriToModuleName.put(namespace, latestModule.name)
        }
        return namespace
    }

    def CharSequence toRestconfIdentifier(QName qname) {
        checkPreconditions
        var module = uriToModuleName.get(qname.namespace)
        if (module === null) {
            val moduleSchema = globalSchema.findModuleByNamespaceAndRevision(qname.namespace, qname.revision);
            if(moduleSchema === null) throw new IllegalArgumentException()
            uriToModuleName.put(qname.namespace, moduleSchema.name)
            module = moduleSchema.name;
        }
        return '''«module»:«qname.localName»''';
    }

    private static dispatch def DataSchemaNode childByQName(ChoiceNode container, QName name) {
        for (caze : container.cases) {
            val ret = caze.childByQName(name)
            if (ret !== null) {
                return ret;
            }
        }
        return null;
    }

    private static dispatch def DataSchemaNode childByQName(ChoiceCaseNode container, QName name) {
        val ret = container.getDataChildByName(name);
        return ret;
    }

    private static dispatch def DataSchemaNode childByQName(ContainerSchemaNode container, QName name) {
        return container.dataNodeChildByQName(name);
    }

    private static dispatch def DataSchemaNode childByQName(ListSchemaNode container, QName name) {
        return container.dataNodeChildByQName(name);
    }

    private static dispatch def DataSchemaNode childByQName(DataSchemaNode container, QName name) {
        return null;
    }

    private static def DataSchemaNode dataNodeChildByQName(DataNodeContainer container, QName name) {
        var ret = container.getDataChildByName(name);
        if (ret === null) {

            // Find in Choice Cases
            for (node : container.childNodes) {
                if (node instanceof ChoiceCaseNode) {
                    val caseNode = (node as ChoiceCaseNode);
                    ret = caseNode.childByQName(name);
                    if (ret !== null) {
                        return ret;
                    }
                }
            }
        }
        return ret;
    }

    private def toUriString(Object object) {
        if(object === null) return "";
        return URLEncoder.encode(object.toString)
    }
    
    private def InstanceIdWithSchemaNode collectPathArguments(InstanceIdentifierBuilder builder, List<String> strings,
        DataNodeContainer parentNode, MountInstance mountPoint) {
        checkNotNull(strings)
        if (parentNode === null) {
            return null;
        }
        if (strings.empty) {
            return new InstanceIdWithSchemaNode(builder.toInstance, parentNode as DataSchemaNode, mountPoint)
        }
        
        val nodeName = strings.head.toNodeName
        val moduleName = strings.head.toModuleName
        var DataSchemaNode targetNode = null
        if (!moduleName.nullOrEmpty) {
            // if it is mount point
            if (moduleName == MOUNT_MODULE && nodeName == MOUNT_NODE) {
                if (mountPoint !== null) {
                    throw new ResponseException(BAD_REQUEST, "Restconf supports just one mount point in URI.")
                }
                
                if (mountService === null) {
                    throw new ResponseException(SERVICE_UNAVAILABLE, "MountService was not found. " 
                        + "Finding behind mount points does not work."
                    )
                }
                
                val partialPath = builder.toInstance;
                val mount = mountService.getMountPoint(partialPath)
                if (mount === null) {
                    LOG.debug("Instance identifier to missing mount point: {}", partialPath)
                    throw new ResponseException(BAD_REQUEST, "Mount point does not exist.")
                }
                
                val mountPointSchema = mount.schemaContext;
                if (mountPointSchema === null) {
                    throw new ResponseException(BAD_REQUEST, "Mount point does not contain any schema with modules.")
                }
                
                if (strings.size == 1) { // any data node is not behind mount point
                    return new InstanceIdWithSchemaNode(InstanceIdentifier.builder().toInstance, mountPointSchema, mount)
                }
                
                val moduleNameBehindMountPoint = strings.get(1).toModuleName()
                if (moduleNameBehindMountPoint === null) {
                    throw new ResponseException(BAD_REQUEST,
                        "First node after mount point in URI has to be in format \"moduleName:nodeName\"")
                }
                
                val moduleBehindMountPoint = mountPointSchema.getLatestModule(moduleNameBehindMountPoint)
                if (moduleBehindMountPoint === null) {
                    throw new ResponseException(BAD_REQUEST,
                        "URI has bad format. \"" + moduleName + "\" module does not exist in mount point.")
                }
                
                return collectPathArguments(InstanceIdentifier.builder(), strings.subList(1, strings.size),
                    moduleBehindMountPoint, mount);
            }
            
            var Module module = null;
            if (mountPoint === null) {
                module = globalSchema.getLatestModule(moduleName)
                if (module === null) {
                    throw new ResponseException(BAD_REQUEST,
                        "URI has bad format. \"" + moduleName + "\" module does not exist.")
                }
            } else {
                module = mountPoint.schemaContext?.getLatestModule(moduleName)
                if (module === null) {
                    throw new ResponseException(BAD_REQUEST,
                        "URI has bad format. \"" + moduleName + "\" module does not exist in mount point.")
                }
            }
            targetNode = parentNode.findInstanceDataChild(nodeName, module.namespace)
            if (targetNode === null) {
                throw new ResponseException(BAD_REQUEST, "URI has bad format. Possible reasons:\n" + 
                    "1. \"" + strings.head + "\" was not found in parent data node.\n" + 
                    "2. \"" + strings.head + "\" is behind mount point. Then it should be in format \"/" + MOUNT + "/" + strings.head + "\".")
            }
        } else { // string without module name
            targetNode = parentNode.findInstanceDataChild(nodeName, null)
            if (targetNode === null) {
                throw new ResponseException(BAD_REQUEST, "URI has bad format. \"" + nodeName + "\" was not found in parent data node.\n")
            }
        }
        
        // Number of consumed elements
        var consumed = 1;
        if (targetNode instanceof ListSchemaNode) {
            val listNode = targetNode as ListSchemaNode;
            val keysSize = listNode.keyDefinition.size

            // every key has to be filled
            if ((strings.length - consumed) < keysSize) {
                throw new ResponseException(BAD_REQUEST,"Missing key for list \"" + listNode.QName.localName + "\".")
            }
            val uriKeyValues = strings.subList(consumed, consumed + keysSize);
            val keyValues = new HashMap<QName, Object>();
            var i = 0;
            for (key : listNode.keyDefinition) {
                val uriKeyValue = uriKeyValues.get(i);

                // key value cannot be NULL
                if (uriKeyValue.equals(NULL_VALUE)) {
                    throw new ResponseException(BAD_REQUEST, "URI has bad format. List \"" + listNode.QName.localName 
                        + "\" cannot contain \"null\" value as a key."
                    )
                }
                keyValues.addKeyValue(listNode.getDataChildByName(key), uriKeyValue);
                i = i + 1;
            }
            consumed = consumed + i;
            builder.nodeWithKey(targetNode.QName, keyValues);
        } else {

            // Only one instance of node is allowed
            builder.node(targetNode.QName);
        }
        if (targetNode instanceof DataNodeContainer) {
            val remaining = strings.subList(consumed, strings.length);
            val result = builder.collectPathArguments(remaining, targetNode as DataNodeContainer, mountPoint);
            return result
        }

        return new InstanceIdWithSchemaNode(builder.toInstance, targetNode, mountPoint)
    }

    def DataSchemaNode findInstanceDataChild(DataNodeContainer container, String name, URI moduleNamespace) {
        var DataSchemaNode potentialNode = null
        if (moduleNamespace === null) {
            potentialNode = container.getDataChildByName(name);
        } else {
            potentialNode = container.childNodes.filter[n|n.QName.localName == name && n.QName.namespace == moduleNamespace].head
        }
        
        if (potentialNode.instantiatedDataSchema) {
            return potentialNode;
        }
        val allCases = container.childNodes.filter(ChoiceNode).map[cases].flatten
        for (caze : allCases) {
            potentialNode = caze.findInstanceDataChild(name, moduleNamespace);
            if (potentialNode !== null) {
                return potentialNode;
            }
        }
        return null;
    }
    
    static def boolean isInstantiatedDataSchema(DataSchemaNode node) {
        switch node {
            LeafSchemaNode: return true
            LeafListSchemaNode: return true
            ContainerSchemaNode: return true
            ListSchemaNode: return true
            default: return false
        }
    }

    private def void addKeyValue(HashMap<QName, Object> map, DataSchemaNode node, String uriValue) {
        checkNotNull(uriValue);
        checkArgument(node instanceof LeafSchemaNode);
        val urlDecoded = URLDecoder.decode(uriValue);
        val typedef = (node as LeafSchemaNode).type;
        
        var decoded = TypeDefinitionAwareCodec.from(typedef)?.deserialize(urlDecoded)
        if(decoded === null) {
            var baseType = RestUtil.resolveBaseTypeFrom(typedef)
            if(baseType instanceof IdentityrefTypeDefinition) {
                decoded = toQName(urlDecoded)
            }
        }
        map.put(node.QName, decoded);
    }

    private static def String toModuleName(String str) {
        checkNotNull(str)
        if (str.contains(":")) {
            val args = str.split(":");
            if (args.size === 2) {
                return args.get(0);
            }
        }
        return null;
    }

    private def String toNodeName(String str) {
        if (str.contains(":")) {
            val args = str.split(":");
            if (args.size === 2) {
                return args.get(1);
            }
        }
        return str;
    }

    private def QName toQName(String name) {
        val module = name.toModuleName;
        val node = name.toNodeName;
        val namespace = FluentIterable.from(globalSchema.modules.sort[o1,o2 | o1.revision.compareTo(o2.revision)]) //
            .transform[QName.create(namespace,revision,it.name)].findFirst[module == localName]
        ;
        return QName.create(namespace,node);
    }

    def getRpcDefinition(String name) {
        return qnameToRpc.get(name.toQName)
    }

    override onGlobalContextUpdated(SchemaContext context) {
        this.globalSchema = context;
        for (operation : context.operations) {
            val qname = operation.QName;
            qnameToRpc.put(qname, operation);
        }
    }

}
