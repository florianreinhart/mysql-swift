//
//  Connection.swift
//  MySQL
//
//  Created by ito on 2015/10/24.
//  Copyright © 2015年 Yusuke Ito. All rights reserved.
//

import CMySQL
import SQLFormatter

public struct QueryStatus: CustomStringConvertible {
    public let affectedRows: Int
    public let insertedId: Int
    
    init(mysql: UnsafeMutablePointer<MYSQL>) {
        self.insertedId = Int(mysql_insert_id(mysql))
        let arows = mysql_affected_rows(mysql)
        if arows == (~0) {
            self.affectedRows = 0 // error or select statement
        } else {
            self.affectedRows = Int(arows)
        }
    }
    
    public var description: String {
        return "inserted id = \(insertedId), affected rows = \(affectedRows)"
    }
}

extension String {
    func subString(max: Int) -> String {
        return self[startIndex..<startIndex.advanced(by: max, limit: endIndex)]
    }
}

extension Connection {
    
    internal struct NullValue {
        static let null = NullValue()
    }
    
    internal struct EmptyRowResult: QueryRowResultType {
        static func decodeRow(r: QueryRowResult) throws -> EmptyRowResult {
            return EmptyRowResult()
        }
    }
    
    internal struct Field {
        let name: String
        let type: enum_field_types
        let isBinary: Bool
        let flags: UInt32
        init?(f: MYSQL_FIELD) {
            if f.name == nil {
                return nil
            }
            guard let fs = String(validatingUTF8: f.name) else {
                return nil
            }
            self.name = fs
            self.type = f.type
            self.flags = f.flags
            self.isBinary = f.flags & UInt32(BINARY_FLAG) > 0 ? true : false
        }
        var isDate: Bool {
            return type == MYSQL_TYPE_DATE ||
                type == MYSQL_TYPE_DATETIME ||
                type == MYSQL_TYPE_TIME ||
                type == MYSQL_TYPE_TIMESTAMP
        }
        
    }
    
    enum FieldValue {
        case Null
        case Binary(SQLBinary) // Note: bytes includes utf8 terminating character(0) at end
        case Date(SQLDate)
        
        static func makeBinary(ptr: UnsafeMutablePointer<Int8>, length: UInt) -> FieldValue {
            var bytes = Array<Int8>.init(repeating: 0, count: Int(length+1))
            for i in 0..<Int(length) {
                bytes[i] = ptr[i]
            }
            return FieldValue.Binary( SQLBinary(buffer: bytes, length: Int(length)) )
        }
        
        func string() throws -> String {
            switch self {
            case .Null:
                fatalError() // TODO
            case .Date:
                fatalError() // TODO
            case .Binary(let binary):
                guard let string = String(validatingUTF8: binary.buffer) else {
                    throw QueryError.ResultParseError(message: "", result: "")
                }
                return string
            }
        }
    }
    
    private func query<T: QueryRowResultType>(query formattedQuery: String) throws -> ([T], QueryStatus) {
        let mysql = try connectIfNeeded()
        
        func queryPrefix() -> String {
            if options.omitDetailsOnError {
                return ""
            }
            return formattedQuery.subString(max: 1000)
        }
        
        guard mysql_real_query(mysql, formattedQuery, UInt(formattedQuery.utf8.count)) == 0 else {
            throw QueryError.QueryExecutionError(message: MySQLUtil.getMySQLError(mysql), query: queryPrefix())
        }
        let status = QueryStatus(mysql: mysql)
        
        let res = mysql_use_result(mysql)
        guard res != nil else {
            if mysql_field_count(mysql) == 0 {
                // actual no result
                return ([], status)
            }
            throw QueryError.ResultFetchError(message: MySQLUtil.getMySQLError(mysql), query: queryPrefix())
        }
        defer {
            mysql_free_result(res)
        }
        
        let fieldCount = Int(mysql_num_fields(res))
        guard fieldCount > 0 else {
            throw QueryError.ResultNoField(query: queryPrefix())
        }
        
        // fetch field info
        let fieldDef = mysql_fetch_fields(res)
        guard fieldDef != nil else {
            throw QueryError.ResultFieldFetchError(query: queryPrefix())
        }
        var fields:[Field] = []
        for i in 0..<fieldCount {
            guard let f = Field(f: fieldDef[i]) else {
                throw QueryError.ResultFieldFetchError(query: queryPrefix())
            }
            fields.append(f)
        }
        
        // fetch rows
        var rows:[QueryRowResult] = []
        
        var rowCount: Int = 0
        while true {
            guard let row = mysql_fetch_row(res) else {
                break
            }
            
            let lengths = mysql_fetch_lengths(res)
            
            var cols:[FieldValue] = []
            for i in 0..<fieldCount {
                let field = fields[i]
                if let valf = row[i] where row[i] != nil {
                    let binary = FieldValue.makeBinary(ptr: valf, length: lengths[i])
                    if field.isDate {
                        cols.append(FieldValue.Date(try SQLDate(sqlDate: binary.string(), timeZone: options.timeZone)))
                    } else {
                        cols.append(binary)
                    }                    
                } else {
                    cols.append(FieldValue.Null)
                }
                
            }
            rowCount += 1
            if fields.count != cols.count {
                throw QueryError.ResultParseError(message: "invalid fetched column count", result: "")
            }
            rows.append(QueryRowResult(fields: fields, cols: cols))
        }
        
        return try (rows.map({ try T.decodeRow(r: $0) }), status)
    }
}

public struct QueryParameterOption: QueryParameterOptionType {
    let timeZone: Connection.TimeZone
}


extension Connection {
    
    internal static func buildArgs(_ args: [QueryParameter], option: QueryParameterOption) throws -> [QueryParameterType] {
        return try args.map { arg in
            if let val = arg as? String {
                return val
            }
            return try arg.queryParameter(option: option)
        }
    }
    
    public func query<T: QueryRowResultType>(_ query: String, _ args: [QueryParameter] = []) throws -> ([T], QueryStatus) {
        let option = QueryParameterOption(
            timeZone: options.timeZone
        )
        let queryString = try QueryFormatter.format(query: query, args: self.dynamicType.buildArgs(args, option: option))
        return try self.query(query: queryString)
    }
    
    public func query<T: QueryRowResultType>(_ query: String, _ args: [QueryParameter] = []) throws -> [T] {
        let (rows, _) = try self.query(query, args) as ([T], QueryStatus)
        return rows
    }
    
    public func query(_ query: String, _ args: [QueryParameter] = []) throws -> QueryStatus {
        let (_, status) = try self.query(query, args) as ([EmptyRowResult], QueryStatus)
        return status
    }
}